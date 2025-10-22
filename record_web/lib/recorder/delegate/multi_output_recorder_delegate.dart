import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:record_web/encoder/encoder.dart';
import 'package:record_web/encoder/wav_encoder.dart';
import 'package:record_web/mime_types.dart';
import 'package:record_web/recorder/delegate/recorder_delegate.dart';
import 'package:record_web/recorder/recorder.dart';
import 'package:record_web/services/audio_chunks_storage_service.dart';
import 'package:web/web.dart' as web;

/// Web delegate that supports dual-output recording:
/// - Streams PCM S16LE frames to Dart
/// - Writes WAV using custom encoder and AAC/Opus using MediaRecorder
class MultiOutputRecorderDelegate extends RecorderDelegate {
  final OnStateChanged onStateChanged;

  // Media stream and audio processing
  web.MediaStream? _mediaStream;
  web.AudioContext? _context;
  web.AudioWorkletNode? _workletNode;
  web.MediaStreamAudioSourceNode? _source;

  // Streaming
  StreamController<Uint8List>? _recordStreamCtrl;

  // WAV encoder (manual)
  Encoder? _wavEncoder;

  // MediaRecorder for compressed branch (AAC/Opus depending on browser)
  web.MediaRecorder? _mediaRecorder;
  List<web.Blob> _compressedChunks = [];

  // Cached result URL for compressed branch
  String? _compressedUrl;

  // Amplitude (computed from PCM frames)
  double _maxAmplitude = kMinAmplitude;
  double _amplitude = kMinAmplitude;

  // Debug counters
  int _pcmChunkCount = 0;
  int _pcmByteCount = 0;
  int _compressedChunkCount = 0;
  int _compressedByteCount = 0;

  // Persistent storage for crash recovery
  final _storageService = AudioChunksStorageService();
  String? _currentRecordingId;

  MultiOutputRecorderDelegate({required this.onStateChanged});

  @override
  Future<void> dispose() async {
    await stopDual();
    await _storageService.close();
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

    debugPrint('[record_web] startStreamDual -> encoder=${config.encoder} sr=${config.sampleRate} ch=${config.numChannels}');

    // Use basePath as recording ID (consistent with Android/iOS)
    _currentRecordingId = basePath;
    debugPrint('[record_web] startStreamDual -> recordingId=$_currentRecordingId');

    // Reset counters and previous branch caches
    _pcmChunkCount = 0;
    _pcmByteCount = 0;
    _compressedChunkCount = 0;
    _compressedByteCount = 0;
    _compressedUrl = null;

    await _recordStreamCtrl?.close();
    _recordStreamCtrl = StreamController<Uint8List>();

    // Setup microphone capture
    final mediaStream = await initMediaStream(config);
    final context = getContext(mediaStream, config);
    final source = context.createMediaStreamSource(mediaStream);
    final workletNode = await _createWorkletNode(context, config);
    source.connect(workletNode)?.connect(context.destination);

    // WAV branch: always available since we have PCM frames
    _wavEncoder?.cleanup();
    _wavEncoder = WavEncoder(
      sampleRate: config.sampleRate.toInt(),
      numChannels: config.numChannels,
    );
    debugPrint('[record_web] Dual WAV branch initialized');

    // Compressed branch: use MediaRecorder if supported
    try {
      final preferredMime = getSupportedMimeType(AudioEncoder.aacLc) ?? getSupportedMimeType(AudioEncoder.opus);

      if (preferredMime != null) {
        final mr = web.MediaRecorder(
          mediaStream,
          web.MediaRecorderOptions(mimeType: preferredMime),
        );
        mr.ondataavailable = ((web.BlobEvent e) => _onCompressedData(e)).toJS;
        mr.onstop = ((web.Event e) => _onCompressedStop()).toJS;
        mr.start(200);
        _mediaRecorder = mr;
        debugPrint('[record_web] Compressed branch initialized -> mime=$preferredMime');
      }
    } catch (e) {
      debugPrint('[record_web] MediaRecorder unavailable for compressed branch: $e');
      _mediaRecorder = null; // compressed branch disabled
    }

    // Wire PCM streaming and amplitude + WAV encoding
    workletNode.port.onmessage = ((web.MessageEvent e) => _onPcmMessage(e)).toJS;

    _source = source;
    _workletNode = workletNode;
    _context = context;
    _mediaStream = mediaStream;

    onStateChanged(RecordState.record);
    debugPrint('[record_web] startStreamDual -> recording started');

    return _recordStreamCtrl!.stream;
  }

  @override
  @override
  Future<MultiOutputResult> stopDual() async {
    debugPrint('[record_web] stopDual -> starting stop process');
    debugPrint('[record_web] stopDual -> current chunks: ${_compressedChunks.length}');

    // Tear down audio context/stream graph first
    await resetContext(_context, _mediaStream);
    _mediaStream = null;
    _context = null;

    // Store blobs and MIME type
    web.Blob? compressedBlob;
    String? compressedMimeType;

    // Stop MediaRecorder branch if running
    if (_mediaRecorder?.state == 'recording' || _mediaRecorder?.state == 'paused') {
      debugPrint('[record_web] stopDual -> stopping MediaRecorder (state: ${_mediaRecorder?.state})');

      // Store MIME type before stopping
      compressedMimeType = _mediaRecorder?.mimeType;
      debugPrint('[record_web] stopDual -> MediaRecorder mimeType: $compressedMimeType');

      // Create a completer to wait for onstop event
      final stopCompleter = Completer<void>();

      _mediaRecorder?.onstop = ((web.Event e) {
        debugPrint('[record_web] stopDual -> onstop event fired');
        // _onCompressedStop();
        stopCompleter.complete();
      }).toJS;

      _mediaRecorder?.stop();

      // Wait for stop event with timeout
      try {
        await stopCompleter.future.timeout(Duration(seconds: 5));
        debugPrint('[record_web] stopDual -> MediaRecorder stopped successfully');
      } catch (e) {
        debugPrint('[record_web] stopDual -> MediaRecorder stop timeout: $e');
      }
    } else {
      debugPrint('[record_web] stopDual -> MediaRecorder not running (state: ${_mediaRecorder?.state})');
    }

    // Create compressed blob from chunks (don't rely on _onCompressedStop)
    if (_compressedChunks.isNotEmpty) {
      debugPrint('[record_web] stopDual -> creating compressed blob from ${_compressedChunks.length} chunks');
      compressedBlob = web.Blob(_compressedChunks.toJS);

      // Use stored MIME type or fallback
      if (compressedMimeType == null || compressedMimeType.isEmpty) {
        compressedMimeType = compressedBlob.type.isNotEmpty ? compressedBlob.type : 'audio/mp4';
        debugPrint('[record_web] stopDual -> using fallback mimeType: $compressedMimeType');
      }

      debugPrint(
          '[record_web] stopDual -> compressed blob created: size=${compressedBlob.size}, type=${compressedBlob.type}, mimeType=$compressedMimeType');
    } else {
      debugPrint('[record_web] stopDual -> no compressed chunks available');
    }

    // Finalize WAV branch
    web.Blob? wavBlob;
    try {
      wavBlob = _wavEncoder?.finish();
      debugPrint('[record_web] stopDual -> WAV encoder finished, blob size: ${wavBlob?.size}');
      _wavEncoder?.cleanup();
      _wavEncoder = null;
      if (wavBlob != null) {
        debugPrint('[record_web] stopDual -> WAV blob created: size=${wavBlob.size}');
      } else {
        debugPrint('[record_web] stopDual -> WAV encoder returned null blob');
      }
    } catch (e) {
      debugPrint('[record_web] stopDual -> WAV encoding error: $e');
    }

    onStateChanged(RecordState.stop);

    // Clear compressed chunks after using them
    _compressedChunks = [];

    final currentRecordingId = _currentRecordingId;
    if (currentRecordingId != null) {
      _storageService.deleteChunks(currentRecordingId).catchError((e) {
        if (kDebugMode) {
          print('[record_web] Error deleting stored chunks: $e');
        }
      });
      _currentRecordingId = null;
    }

    final result = MultiOutputResult(
      m4aPath: null, // Don't return URLs on web
      wavPath: null, // Don't return URLs on web
      m4aBlob: compressedBlob,
      wavBlob: wavBlob,
      m4aMimeType: compressedMimeType,
      m4aError: compressedBlob == null ? 'Compressed branch not available' : null,
      wavError: wavBlob == null ? 'WAV encoding failed or no data' : null,
    );

    debugPrint('[record_web] stopDual -> final result:');
    debugPrint('[record_web] stopDual ->   m4aBlob: ${result.m4aBlob?.size} bytes');
    debugPrint('[record_web] stopDual ->   wavBlob: ${result.wavBlob?.size} bytes');
    debugPrint('[record_web] stopDual ->   m4aMimeType: ${result.m4aMimeType}');
    debugPrint('[record_web] stopDual ->   m4aError: ${result.m4aError}');
    debugPrint('[record_web] stopDual ->   wavError: ${result.wavError}');
    debugPrint('[record_web] stopDual ->   isSuccess: ${result.isSuccess}');

    return result;
  }

  void _onPcmMessage(web.MessageEvent event) {
    // data is Int16Array
    final output = (event.data as JSInt16Array?)?.toDart;
    if (output case final out?) {
      final bytes = out.buffer.asUint8List();
      _recordStreamCtrl?.add(bytes);
      // Feed WAV branch
      _wavEncoder?.encode(out);
      _updateAmplitude(out);
      _pcmChunkCount++;
      _pcmByteCount += bytes.length;

      final currentRecordingId = _currentRecordingId;
      if (currentRecordingId == null) {
        throw StateError('Recording ID is null during PCM recording');
      }
      _saveChunkToStorage(
        recordingId: currentRecordingId,
        chunkIndex: _pcmChunkCount,
        chunkData: bytes,
        chunkType: 'PCM',
      );

      if ((_pcmChunkCount % 50) == 0) {
        debugPrint('[record_web] PCM stream -> chunks=$_pcmChunkCount bytes=$_pcmByteCount');
      }
    }
  }

  void _saveChunkToStorage({
    required String recordingId,
    required int chunkIndex,
    required Uint8List chunkData,
    required String chunkType,
  }) {
    _storageService
        .saveChunk(
      recordingId: recordingId,
      chunkIndex: chunkIndex,
      chunkData: chunkData,
    )
        .catchError((e) {
      if (kDebugMode) {
        print('[record_web] Error saving $chunkType chunk: $e');
      }
    });
  }

  void _onCompressedData(web.BlobEvent event) {
    final data = event.data;
    if (data.size > 0) {
      _compressedChunks.add(data);
      _compressedChunkCount++;
      _compressedByteCount += data.size.toInt();

      final currentRecordingId = _currentRecordingId;
      if (currentRecordingId == null) {
        throw StateError('Recording ID is null during compressed recording');
      }
      _saveCompressedBlobAsChunk(
        blob: data,
        recordingId: currentRecordingId,
        chunkIndex: _compressedChunkCount,
      );

      if ((_compressedChunkCount % 10) == 0) {
        debugPrint('[record_web] Compressed stream -> chunks=$_compressedChunkCount bytes=$_compressedByteCount');
      }
    } else {
      debugPrint('[record_web] Compressed stream -> received empty chunk');
    }
  }

  void _saveCompressedBlobAsChunk({
    required web.Blob blob,
    required String recordingId,
    required int chunkIndex,
  }) {
    final reader = web.FileReader();
    reader.onloadend = ((web.Event e) async {
      final result = reader.result;
      if (result != null) {
        final bytes = (result as JSArrayBuffer).toDart.asUint8List();
        _saveChunkToStorage(
          recordingId: recordingId,
          chunkIndex: chunkIndex,
          chunkData: bytes,
          chunkType: 'compressed',
        );
      }
    }).toJS;
    reader.readAsArrayBuffer(blob);
  }

  void _onCompressedStop() {
    debugPrint('[record_web] _onCompressedStop -> called with ${_compressedChunks.length} chunks');
    if (_compressedChunks.isEmpty) {
      debugPrint('[record_web] _onCompressedStop -> no chunks to process');
      return;
    }
    final blob = web.Blob(_compressedChunks.toJS);
    _compressedUrl = web.URL.createObjectURL(blob);
    debugPrint('[record_web] _onCompressedStop -> created compressed blob URL: $_compressedUrl');
    _compressedChunks = [];
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

  void _updateAmplitude(Int16List data) {
    var maxSample = kMinAmplitude;
    for (var i = 0; i < data.length; i++) {
      final v = data[i].abs();
      if (v > maxSample) maxSample = v.toDouble();
    }
    _amplitude = 20 * (log(maxSample / 32767) / ln10);
    if (_amplitude > _maxAmplitude) {
      _maxAmplitude = _amplitude;
    }
  }
}
