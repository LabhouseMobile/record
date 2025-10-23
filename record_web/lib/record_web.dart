import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:record_web/encoder/wav_encoder.dart';
import 'package:record_web/recorder/recorder.dart';
import 'package:record_web/services/audio_chunks_storage_service.dart';
import 'package:record_web/services/metadata_storage_service.dart';
import 'package:web/web.dart' as web;

class RecordPluginWeb {
  static void registerWith(Registrar registrar) {
    RecordPlatform.instance = RecordPluginWebWrapper();
  }
}

class RecordPluginWebWrapper extends RecordPlatform {
  // recorders from recorderId
  final _recorders = <String, Recorder>{};

  // Shared storage services for recovery
  final _chunksService = AudioChunksStorageService();
  final _metadataService = MetadataStorageService();

  @override
  Future<void> create(String recorderId) async {
    _recorders[recorderId] = Recorder();
  }

  @override
  Future<void> dispose(String recorderId) async {
    final recorder = _getRecorder(recorderId);
    await recorder.dispose();

    _recorders.remove(recorderId);
  }

  @override
  Future<bool> hasPermission(String recorderId) {
    return _getRecorder(recorderId).hasPermission();
  }

  @override
  Future<bool> isPaused(String recorderId) {
    return _getRecorder(recorderId).isPaused();
  }

  @override
  Future<bool> isRecording(String recorderId) {
    return _getRecorder(recorderId).isRecording();
  }

  @override
  Future<void> pause(String recorderId) {
    return _getRecorder(recorderId).pause();
  }

  @override
  Future<void> resume(String recorderId) {
    return _getRecorder(recorderId).resume();
  }

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) {
    return _getRecorder(recorderId).start(config, path: path);
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) {
    return _getRecorder(recorderId).startStream(config);
  }

  @override
  Future<Stream<Uint8List>> startStreamDual(
    String recorderId,
    RecordConfig config, {
    required String basePath,
  }) {
    return _getRecorder(recorderId).startStreamDual(config, basePath: basePath);
  }

  @override
  Future<String?> stop(String recorderId) {
    return _getRecorder(recorderId).stop();
  }

  @override
  Future<MultiOutputResult> stopDual(String recorderId) {
    return _getRecorder(recorderId).stopDual();
  }

  @override
  Future<void> cancel(String recorderId) {
    return _getRecorder(recorderId).cancel();
  }

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) {
    return _getRecorder(recorderId).listInputDevices();
  }

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) {
    return _getRecorder(recorderId).isEncoderSupported(encoder);
  }

  @override
  Future<Amplitude> getAmplitude(String recorderId) {
    return _getRecorder(recorderId).getAmplitude();
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) {
    return _getRecorder(recorderId).onStateChanged();
  }

  Recorder _getRecorder(String recorderId) {
    final recorder = _recorders[recorderId];

    if (recorder == null) {
      throw PlatformException(
        code: 'record',
        message: 'Record has not yet been created or has already been disposed.',
      );
    }

    return recorder;
  }

  /// Recovers a pending recording by path, reconstructed as a complete WAV file
  ///
  /// Returns the complete WAV file as bytes if found, or null if no recording exists.
  /// This is useful for crash recovery - if the app crashed during recording,
  /// you can attempt to recover the audio that was saved to IndexedDB.
  ///
  /// The returned bytes are a complete WAV file with headers, ready to upload or save.
  @override
  Future<Uint8List?> recoverRecording(String path) async {
    final chunks = await _chunksService.getChunks(path);
    if (chunks.isEmpty) return null;

    final metadata = await _metadataService.getMetadata(path);
    if (metadata == null) return null;

    final wavEncoder = _createWavEncoderFromMetadata(metadata);
    for (final chunk in chunks) {
      final int16Data = Int16List.view(chunk.buffer);
      wavEncoder.encode(int16Data);
    }
    final wavBlob = wavEncoder.finish();

    // Convert Blob to Uint8List
    final reader = web.FileReader();
    final completer = Completer<Uint8List>();

    reader.onloadend = ((web.Event e) {
      try {
        final result = reader.result;
        final bytes = _convertReaderResultToUint8List(result);
        completer.complete(bytes);
      } catch (e) {
        completer.completeError(e);
      }
    }).toJS;

    reader.onerror = ((web.Event e) {
      completer.completeError('Error reading WAV blob');
    }).toJS;

    reader.readAsArrayBuffer(wavBlob);

    return completer.future;
  }

  WavEncoder _createWavEncoderFromMetadata(Map<String, dynamic> metadata) {
    final sampleRate = metadata['sampleRate'] as int? ?? 44100;
    final numChannels = metadata['numChannels'] as int? ?? 1;
    return WavEncoder(
      sampleRate: sampleRate,
      numChannels: numChannels,
    );
  }

  Uint8List _convertReaderResultToUint8List(JSAny? result) {
    if (result != null) {
      return (result as JSArrayBuffer).toDart.asUint8List();
    } else {
      throw Exception('Failed to read WAV blob');
    }
  }

  /// Deletes a pending recording by path
  ///
  /// Use this to clean up stored chunks after successful recovery
  /// or if the user chooses to discard the pending recording.
  @override
  Future<void> deleteRecording(String path) async {
    await _chunksService.deleteChunks(path);
    await _metadataService.deleteMetadata(path);
  }
}
