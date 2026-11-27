import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:record_web/encoder/wav_encoder.dart';
import 'package:record_web/mime_types.dart';
import 'package:record_web/recorder/delegate/multi_output_errors.dart';
import 'package:record_web/recorder/delegate/recorder_delegate.dart';
import 'package:record_web/recorder/recorder.dart';
import 'package:record_web/services/audio_chunks_storage_service.dart';
import 'package:record_web/services/metadata_storage_service.dart';
import 'package:universal_html/html.dart' as html;
import 'package:web/web.dart' as web;

/// Web delegate that supports dual-output recording:
/// - Streams PCM S16LE frames to Dart
/// - Persists PCM chunks to IndexedDB (used as the WAV source on stop and for crash recovery)
/// - Writes AAC/Opus using MediaRecorder
class MultiOutputRecorderDelegate extends RecorderDelegate {
  final OnStateChanged onStateChanged;

  // Media stream and audio processing
  web.MediaStream? _mediaStream;
  web.AudioContext? _context;
  web.AudioWorkletNode? _workletNode;
  web.MediaStreamAudioSourceNode? _source;

  StreamController<Uint8List>? _recordStreamCtrl;

  // MediaRecorder for compressed branch (AAC/Opus depending on browser)
  web.MediaRecorder? _mediaRecorder;
  List<web.Blob> _compressedChunks = [];

  // Amplitude (computed from PCM frames)
  double _maxAmplitude = kMinAmplitude;
  double _amplitude = kMinAmplitude;

  // Chunk counter for storage
  int _pcmChunkCount = 0;

  // Persistent storage for crash recovery — also the source of truth for the WAV blob on stop
  final _chunksService = AudioChunksStorageService();
  final _metadataService = MetadataStorageService();
  String? _currentRecordingId;

  // In-flight IndexedDB writes; the WAV read-back waits for them so it covers every captured chunk
  final List<Future<void>> _pendingWrites = [];

  MultiOutputRecorderDelegate({required this.onStateChanged});

  @override
  Future<void> dispose() async {
    await stopDual();
  }

  @override
  Future<Amplitude> getAmplitude() async {
    return Amplitude(current: _amplitude, max: _maxAmplitude);
  }

  @override
  Future<bool> isPaused() async {
    return _context?.state == 'suspended';
  }

  @override
  Future<bool> isRecording() async {
    final ctx = _context;
    return ctx != null && ctx.state != 'closed';
  }

  @override
  Future<void> pause() async {
    final ctx = _context;
    if (ctx != null && ctx.state == 'running') {
      await ctx.suspend().toDart;
      if (_mediaRecorder?.state == 'recording') {
        _mediaRecorder?.pause();
      }
      onStateChanged(RecordState.pause);
    }
  }

  @override
  Future<void> resume() async {
    final ctx = _context;
    if (ctx != null && ctx.state == 'suspended') {
      await ctx.resume().toDart;
      if (_workletNode != null) {
        // Ensure node is connected after long pauses
        _source?.connect(_workletNode!)?.connect(ctx.destination);
      }
      if (_mediaRecorder?.state == 'paused') {
        _mediaRecorder?.resume();
      }
      onStateChanged(RecordState.record);
    }
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    // Not used in dual-stream mode
    throw UnimplementedError();
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    // Not used; dual mode should call startStreamDual
    throw UnimplementedError();
  }

  @override
  Future<String?> stop() async {
    // Not used in dual mode; use stopDual
    return null;
  }

  @override
  Future<Stream<Uint8List>> startStreamDual(
    RecordConfig config, {
    required String basePath,
  }) async {
    if (config.encoder != AudioEncoder.pcm16bits) {
      throw Exception(
        '${config.encoder} not supported in dual streaming mode. Use pcm16bits encoder.',
      );
    }

    _currentRecordingId = basePath;

    // Reset counter
    _pcmChunkCount = 0;

    unawaited(_deleteOrphanChunks());

    // The orphan sweep deletes chunks without metadata, so the metadata must exist before the first chunk: it is
    // awaited before the PCM handler is connected, and written alongside the microphone setup meanwhile.
    // Best-effort: if this write fails the chunks get swept, which loses nothing since recovery needs it too.
    final metadataSaved = _saveMetadataForRecovery(
      recordingId: basePath,
      sampleRate: config.sampleRate.toInt(),
      numChannels: config.numChannels,
    );

    await _recordStreamCtrl?.close();
    _recordStreamCtrl = StreamController<Uint8List>();

    await _setupMicrophoneCapture(config);

    await _setupMediaRecorder();

    await metadataSaved;

    // Connect PCM data processing pipeline
    _workletNode?.port.onmessage = ((web.MessageEvent e) => _onPcmMessage(e)).toJS;

    onStateChanged(RecordState.record);

    if (_recordStreamCtrl == null) throw Exception('Record stream controller not initialized');

    return _recordStreamCtrl!.stream;
  }

  Future<void> _saveMetadataForRecovery({
    required String recordingId,
    required int sampleRate,
    required int numChannels,
  }) {
    return _metadataService
        .saveMetadata(
      recordingId: recordingId,
      sampleRate: sampleRate,
      numChannels: numChannels,
    )
        .catchError((e) {
      if (kDebugMode) {
        print('[record_web] Error saving metadata: $e');
      }
    });
  }

  @override
  Future<MultiOutputResult> stopDual() async {
    await resetContext(_context, _mediaStream);
    _mediaStream = null;
    _context = null;

    final compressedBlob = await _stopMediaRecorder();
    // Rebuilding the WAV reads every stored chunk back, so its cost grows with the
    // recording length: only pay it when there is no compressed file to return.
    final wavBlob = compressedBlob == null ? await _buildWavFromStoredChunks() : null;

    onStateChanged(RecordState.stop);

    _compressedChunks = [];

    final currentRecordingId = _currentRecordingId;
    if (currentRecordingId != null) {
      await _forgetStoredRecording(currentRecordingId);
      _currentRecordingId = null;
    }

    final result = MultiOutputResult(
      m4aPath: null, // Don't return paths on web
      wavPath: null, // Don't return paths on web
      m4aBlob: compressedBlob as html.Blob?,
      wavBlob: wavBlob as html.Blob?,
      m4aError: compressedBlob == null ? 'Compressed branch not available' : null,
      wavError: wavErrorFor(hasWav: wavBlob != null, hasCompressed: compressedBlob != null),
    );

    return result;
  }

  /// Makes [recordingId] unrecoverable right away by deleting its metadata, then deletes its chunks in the
  /// background: that delete grows with the recording length (~2.5 s per hour). It needn't wait for in-flight
  /// chunk writes: they created their transactions first, and IndexedDB runs overlapping transactions in creation
  /// order. Chunks left behind by a tab closed meanwhile are deleted by the orphan sweep.
  Future<void> _forgetStoredRecording(String recordingId) async {
    _pendingWrites.clear();
    try {
      await _metadataService.deleteMetadata(recordingId);
    } catch (e) {
      if (kDebugMode) print('[record_web] Error deleting stored metadata: $e');
    }
    unawaited(_deleteChunks(recordingId));
  }

  Future<void> _deleteChunks(String recordingId) async {
    try {
      await _chunksService.deleteChunks(recordingId);
    } catch (e) {
      if (kDebugMode) print('[record_web] Error deleting stored chunks: $e');
    }
  }

  Future<void> _deleteOrphanChunks() async {
    try {
      await _chunksService.deleteOrphanChunks();
    } catch (e) {
      if (kDebugMode) print('[record_web] Error deleting orphan chunks: $e');
    }
  }

  @override
  Future<void> cancel() async {
    // Close the stream controller without finishing
    await _recordStreamCtrl?.close();
    _recordStreamCtrl = null;

    // Reset audio context and media stream
    await resetContext(_context, _mediaStream);
    _mediaStream = null;
    _context = null;
    _workletNode = null;
    _source = null;

    // Stop media recorder without waiting for data
    _cancelMediaRecorder();

    // Clear compressed chunks
    _compressedChunks = [];

    // Reset amplitude
    _maxAmplitude = kMinAmplitude;
    _amplitude = kMinAmplitude;

    final cancelledRecordingId = _currentRecordingId;
    if (cancelledRecordingId != null) {
      await _forgetStoredRecording(cancelledRecordingId);
      _currentRecordingId = null;
    }

    onStateChanged(RecordState.stop);
  }

  void _cancelMediaRecorder() {
    final mediaRecorder = _mediaRecorder;
    if (mediaRecorder != null && (mediaRecorder.state == 'recording' || mediaRecorder.state == 'paused')) {
      mediaRecorder.stop();
    }
    _mediaRecorder = null;
  }

  void _onPcmMessage(web.MessageEvent event) {
    final pcmData = (event.data as JSInt16Array?)?.toDart;
    if (pcmData case final audioSamples?) {
      final audioBytes = audioSamples.buffer.asUint8List();
      _recordStreamCtrl?.add(audioBytes);
      _updateAmplitude(audioSamples);

      _pcmChunkCount++;
      _saveChunkToStorage(
        chunkIndex: _pcmChunkCount,
        chunkData: audioBytes,
      );
    }
  }

  void _saveChunkToStorage({
    required int chunkIndex,
    required Uint8List chunkData,
  }) {
    final recordingId = _currentRecordingId;
    if (recordingId == null) {
      throw StateError('Recording ID is null during PCM recording');
    }

    final write = _chunksService
        .saveChunk(
      recordingId: recordingId,
      chunkIndex: chunkIndex,
      chunkData: chunkData,
    )
        .catchError((e) {
      if (kDebugMode) {
        print('[record_web] Error saving PCM chunk: $e');
      }
    });
    _pendingWrites.add(write);
  }

  /// Waits for every in-flight chunk write, so the WAV read-back sees all of them.
  Future<void> _drainPendingWrites() async {
    if (_pendingWrites.isEmpty) return;
    final inFlight = List<Future<void>>.from(_pendingWrites);
    _pendingWrites.clear();
    await Future.wait(inFlight);
  }

  Future<web.Blob?> _buildWavFromStoredChunks() async {
    final recordingId = _currentRecordingId;
    if (recordingId == null) return null;

    await _drainPendingWrites();
    try {
      final chunks = await _chunksService.getChunks(recordingId);
      if (chunks.isEmpty) return null;

      final metadata = await _metadataService.getMetadata(recordingId);
      if (metadata == null) return null;

      final encoder = WavEncoder(
        sampleRate: metadata['sampleRate'] as int? ?? 44100,
        numChannels: metadata['numChannels'] as int? ?? 1,
      );
      for (final chunk in chunks) {
        encoder.encode(Int16List.view(chunk.buffer));
      }
      final blob = encoder.finish();
      encoder.cleanup();
      return blob;
    } catch (error) {
      debugPrint(error.toString());
      return null;
    }
  }

  void _onCompressedData(web.BlobEvent event) {
    final compressedChunk = event.data;
    if (compressedChunk.size > 0) {
      _compressedChunks.add(compressedChunk);
    }
  }

  Future<void> _setupMicrophoneCapture(RecordConfig config) async {
    final mediaStream = await initMediaStream(config);
    final context = getContext(mediaStream, config);
    final source = context.createMediaStreamSource(mediaStream);
    final workletNode = await _createWorkletNode(context, config);
    source.connect(workletNode)?.connect(context.destination);

    _source = source;
    _workletNode = workletNode;
    _context = context;
    _mediaStream = mediaStream;
  }

  Future<void> _setupMediaRecorder() async {
    try {
      final preferredMimeType = getSupportedMimeType(AudioEncoder.aacLc) ?? getSupportedMimeType(AudioEncoder.opus);

      if (preferredMimeType != null && _mediaStream != null) {
        final mediaRecorder = web.MediaRecorder(
          _mediaStream!,
          web.MediaRecorderOptions(mimeType: preferredMimeType),
        );
        mediaRecorder.ondataavailable = ((web.BlobEvent e) => _onCompressedData(e)).toJS;
        mediaRecorder.start(200);
        _mediaRecorder = mediaRecorder;
      }
    } catch (er) {
      debugPrint(er.toString());
      _mediaRecorder = null;
    }
  }

  Future<web.AudioWorkletNode> _createWorkletNode(
    web.AudioContext context,
    RecordConfig config,
  ) async {
    await context.audioWorklet.addModule('assets/packages/record_web/assets/js/record.worklet.js').toDart;

    return web.AudioWorkletNode(
      context,
      'recorder.worklet',
      web.AudioWorkletNodeOptions(
        parameterData: {
          'numChannels'.toJS: config.numChannels.toJS,
          'sampleRate'.toJS: config.sampleRate.toJS,
          'streamBufferSize'.toJS: (config.streamBufferSize ?? 2048).toJS,
        }.jsify()! as JSObject,
      ),
    );
  }

  Future<web.Blob?> _stopMediaRecorder() async {
    if (_mediaRecorder?.state != 'recording' && _mediaRecorder?.state != 'paused') {
      return null;
    }

    final stopCompleter = Completer<void>();
    _mediaRecorder?.onstop = ((web.Event event) {
      stopCompleter.complete();
    }).toJS;

    _mediaRecorder?.stop();

    try {
      await stopCompleter.future.timeout(Duration(seconds: 5));
    } catch (error) {
      debugPrint(error.toString());
    }

    if (_compressedChunks.isNotEmpty) {
      return web.Blob(_compressedChunks.toJS);
    }
    return null;
  }

  void _updateAmplitude(Int16List audioData) {
    var maxSample = kMinAmplitude;

    // Find the peak amplitude in the current audio frame
    for (var i = 0; i < audioData.length; i++) {
      var currentSample = audioData[i].abs();
      if (currentSample > maxSample) {
        maxSample = currentSample.toDouble();
      }
    }

    // Convert to decibels (dB)
    _amplitude = 20 * (log(maxSample / 32767) / ln10);

    if (_amplitude > _maxAmplitude) {
      _maxAmplitude = _amplitude;
    }
  }
}
