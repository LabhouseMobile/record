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

  // Streaming
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

    // Compressed branch: use MediaRecorder if supported
    try {
      final preferredMime = getSupportedMimeType(AudioEncoder.aacLc) ?? getSupportedMimeType(AudioEncoder.opus);

      if (preferredMime != null) {
        final mr = web.MediaRecorder(
          mediaStream,
          web.MediaRecorderOptions(mimeType: preferredMime),
        );
        mr.ondataavailable = ((web.BlobEvent e) => _onCompressedData(e)).toJS;
        mr.start(200);
        _mediaRecorder = mr;
      }
    } catch (er) {
      debugPrint(er.toString());
      _mediaRecorder = null; // compressed branch disabled
    }

    // Wire PCM streaming and amplitude + WAV encoding
    workletNode.port.onmessage = ((web.MessageEvent e) => _onPcmMessage(e)).toJS;

    _source = source;
    _workletNode = workletNode;
    _context = context;
    _mediaStream = mediaStream;

    onStateChanged(RecordState.record);

    return _recordStreamCtrl!.stream;
  }

  @override
  Future<MultiOutputResult> stopDual() async {
    // Tear down audio context/stream graph first
    await resetContext(_context, _mediaStream);
    _mediaStream = null;
    _context = null;

    // Store blobs
    web.Blob? compressedBlob;

    // Stop MediaRecorder branch if running
    if (_mediaRecorder?.state == 'recording' || _mediaRecorder?.state == 'paused') {
      // Create a completer to wait for onstop event
      final stopCompleter = Completer<void>();

      _mediaRecorder?.onstop = ((web.Event e) {
        stopCompleter.complete();
      }).toJS;

      _mediaRecorder?.stop();

      // Wait for stop event with timeout
      try {
        await stopCompleter.future.timeout(Duration(seconds: 5));
      } catch (er) {
        debugPrint(er.toString());
      }
    }

    // Create compressed blob from chunks
    if (_compressedChunks.isNotEmpty) {
      compressedBlob = web.Blob(_compressedChunks.toJS);
    }

    // Finalize WAV branch
    web.Blob? wavBlob;
    try {
      wavBlob = _wavEncoder?.finish();
      _wavEncoder?.cleanup();
      _wavEncoder = null;
    } catch (er) {
      debugPrint(er.toString());
    }

    onStateChanged(RecordState.stop);

    // Clear compressed chunks after using them
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

  void _onPcmMessage(web.MessageEvent event) {
    // data is Int16Array
    final output = (event.data as JSInt16Array?)?.toDart;
    if (output case final out?) {
      final bytes = out.buffer.asUint8List();
      _recordStreamCtrl?.add(bytes);
      // Feed WAV branch
      _wavEncoder?.encode(out);
      _updateAmplitude(out);
    }
  }

  void _onCompressedData(web.BlobEvent event) {
    final data = event.data;
    if (data.size > 0) {
      _compressedChunks.add(data);
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

  void _updateAmplitude(Int16List data) {
    var maxSample = kMinAmplitude;

    for (var i = 0; i < data.length; i++) {
      var curSample = data[i].abs();
      if (curSample > maxSample) {
        maxSample = curSample.toDouble();
      }
    }

    _amplitude = 20 * (log(maxSample / 32767) / ln10);

    if (_amplitude > _maxAmplitude) {
      _maxAmplitude = _amplitude;
    }
  }
}
