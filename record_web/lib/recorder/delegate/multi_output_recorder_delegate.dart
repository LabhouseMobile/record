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

  StreamController<Uint8List>? _recordStreamCtrl;

  // WAV encoder (manual)
  Encoder? _wavEncoder;

  // MediaRecorder for compressed branch (AAC/Opus depending on browser)
  web.MediaRecorder? _mediaRecorder;
  List<web.Blob> _compressedChunks = [];

  // Amplitude (computed from PCM frames)
  double _maxAmplitude = kMinAmplitude;
  double _amplitude = kMinAmplitude;

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

    await _recordStreamCtrl?.close();
    _recordStreamCtrl = StreamController<Uint8List>();

    await _setupMicrophoneCapture(config);

    // WAV branch: always available since we have PCM frames
    _wavEncoder?.cleanup();
    _wavEncoder = WavEncoder(
      sampleRate: config.sampleRate.toInt(),
      numChannels: config.numChannels,
    );

    await _setupMediaRecorder();

    // Connect PCM data processing pipeline
    _workletNode?.port.onmessage = ((web.MessageEvent e) => _onPcmMessage(e)).toJS;

    onStateChanged(RecordState.record);

    if (_recordStreamCtrl == null) throw Exception('Record stream controller not initialized');

    return _recordStreamCtrl!.stream;
  }

  @override
  Future<MultiOutputResult> stopDual() async {
    await resetContext(_context, _mediaStream);
    _mediaStream = null;
    _context = null;

    final compressedBlob = await _stopMediaRecorder();
    final wavBlob = await _finalizeWavEncoder();

    onStateChanged(RecordState.stop);

    _compressedChunks = [];

    final result = MultiOutputResult(
      m4aPath: null, // Don't return paths on web
      wavPath: null, // Don't return paths on web
      m4aBlob: compressedBlob,
      wavBlob: wavBlob,
      m4aError: compressedBlob == null ? 'Compressed branch not available' : null,
      wavError: wavBlob == null ? 'WAV encoding failed or no data' : null,
    );

    return result;
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

    // Cleanup WAV encoder without finalizing
    _wavEncoder?.cleanup();
    _wavEncoder = null;

    // Clear compressed chunks
    _compressedChunks = [];

    // Reset amplitude
    _maxAmplitude = kMinAmplitude;
    _amplitude = kMinAmplitude;

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
      // Feed WAV encoder with PCM samples
      _wavEncoder?.encode(audioSamples);
      _updateAmplitude(audioSamples);
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

  Future<web.Blob?> _finalizeWavEncoder() async {
    try {
      final wavBlob = _wavEncoder?.finish();
      _wavEncoder?.cleanup();
      _wavEncoder = null;
      return wavBlob;
    } catch (error) {
      debugPrint(error.toString());
      return null;
    }
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
