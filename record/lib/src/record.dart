import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Audio recorder
class AudioRecorder {
  StreamController<Amplitude>? _amplitudeStreamCtrl;

  StreamController<RecordState>? _stateStreamCtrl;
  StreamSubscription? _stateStreamSubscription;

  StreamController<Uint8List>? _recordStreamCtrl;
  StreamSubscription? _recordStreamSubscription;

  Timer? _amplitudeTimer;
  late Duration _amplitudeTimerInterval;
  final _semaphore = _Semaphore();

  // Recorder ID
  final String _recorderId;

  AudioRecorder() : _recorderId = _uuid.v4() {
    _semaphore.acquire();
    _create().whenComplete(() => _semaphore.release());
  }

  RecordPlatform get _platform => RecordPlatform.instance;

  Future<void> _create() => _platform.create(_recorderId);

  /// Starts new recording session.
  ///
  /// [path]: The output path file. Required on all IO platforms.
  /// On `web`: This parameter is ignored.
  ///
  /// Output path can be retrieves when [stop] method is called.
  Future<void> start(RecordConfig config, {required String path}) async {
    await _safeCall(
      () => _platform.start(_recorderId, config, path: path),
    );

    _startAmplitudeTimer();
  }

  /// Same as [start] with output stream instead of a path.
  ///
  /// When stopping the record, you must rely on stream close event to get
  /// full recorded data.
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    final stream = await _safeCall(
      () async {
        await _stopRecordStream();

        return _platform.startStream(_recorderId, config);
      },
    );

    _recordStreamCtrl = StreamController.broadcast();

    _recordStreamSubscription = stream.listen(
      (data) {
        final streamCtrl = _recordStreamCtrl;
        if (streamCtrl == null || streamCtrl.isClosed) return;

        streamCtrl.add(data);
      },
    );

    _startAmplitudeTimer();

    return _recordStreamCtrl!.stream;
  }

  /// Starts dual-output recording:
  /// - Streams PCM S16LE frames
  /// - Writes `${basePath}.m4a` and `${basePath}.wav` natively (Android/iOS only)
  Future<Stream<Uint8List>> startStreamDual(
    RecordConfig config, {
    required String basePath,
  }) async {
    final stream = await _safeCall(
      () async {
        await _stopRecordStream();

        return _platform.startStreamDual(
          _recorderId,
          config,
          basePath: basePath,
        );
      },
    );

    _recordStreamCtrl = StreamController.broadcast();

    _recordStreamSubscription = stream.listen(
      (data) {
        final streamCtrl = _recordStreamCtrl;
        if (streamCtrl == null || streamCtrl.isClosed) return;

        streamCtrl.add(data);
      },
    );

    _startAmplitudeTimer();

    return _recordStreamCtrl!.stream;
  }

  /// Stops recording session and release internal recorder resource.
  ///
  /// Returns the output path if any.
  Future<String?> stop() async {
    return _safeCall(() async {
      _amplitudeTimer?.cancel();

      final path = await _platform.stop(_recorderId);

      await _stopRecordStream();

      return path;
    });
  }

  /// Stops dual-output recording and returns both paths with per-branch errors.
  Future<MultiOutputResult> stopDual() async {
    return _safeCall(() async {
      _amplitudeTimer?.cancel();

      final result = await _platform.stopDual(_recorderId);

      await _stopRecordStream();

      return result;
    });
  }

  /// Stops and discards/deletes the file/blob.
  Future<void> cancel() async {
    return _safeCall(() async {
      _amplitudeTimer?.cancel();

      await _platform.cancel(_recorderId);

      return _stopRecordStream();
    });
  }

  /// Pauses recording session.
  Future<void> pause() {
    return _safeCall(() {
      _amplitudeTimer?.cancel();

      return _platform.pause(_recorderId);
    });
  }

  /// Resumes recording session after [pause].
  Future<void> resume() {
    return _safeCall(() {
      _startAmplitudeTimer();
      return _platform.resume(_recorderId);
    });
  }

  /// Checks if there's valid recording session.
  /// So if session is paused, this method will still return [true].
  Future<bool> isRecording() {
    return _safeCall(() => _platform.isRecording(_recorderId));
  }

  /// Checks if recording session is paused.
  Future<bool> isPaused() {
    return _safeCall(() => _platform.isPaused(_recorderId));
  }

  /// Checks and requests for audio record permission.
  Future<bool> hasPermission() {
    return _safeCall(() => _platform.hasPermission(_recorderId));
  }

  /// Lists capture/input devices available on the platform.
  ///
  /// On web, and in general, you should already have permission before
  /// accessing this method otherwise the list may return an empty list.
  Future<List<InputDevice>> listInputDevices() {
    return _safeCall(() => _platform.listInputDevices(_recorderId));
  }

  /// Gets current average & max amplitudes (dBFS)
  /// Always returns zeros on unsupported platforms
  Future<Amplitude> getAmplitude() {
    return _safeCall(() => _platform.getAmplitude(_recorderId));
  }

  /// Checks if the given encoder is supported on the current platform.
  Future<bool> isEncoderSupported(AudioEncoder encoder) {
    return _safeCall(() {
      return _platform.isEncoderSupported(_recorderId, encoder);
    });
  }

  /// Dispose the recorder
  Future<void> dispose() {
    return _safeCall(() async {
      _amplitudeTimer?.cancel();
      await _amplitudeStreamCtrl?.close();
      _amplitudeStreamCtrl = null;

      await _stateStreamSubscription?.cancel();
      await _stateStreamCtrl?.close();
      _stateStreamCtrl = null;

      await _stopRecordStream();

      await _platform.dispose(_recorderId);
    });
  }

  /// Listen to recorder states [RecordState].
  ///
  /// Provides pause, resume and stop states.
  ///
  /// Also, you can retrieve async errors from it by adding [Function? onError].
  Stream<RecordState> onStateChanged() {
    if (_stateStreamCtrl == null) {
      _stateStreamCtrl = StreamController<RecordState>.broadcast();

      _safeCall(
        () async {
          final stream = _platform.onStateChanged(_recorderId);

          _stateStreamSubscription = stream.listen(
            (state) {
              if (_stateStreamCtrl case final ctrl? when ctrl.hasListener) {
                ctrl.add(state);
              }
            },
            onError: (error) {
              if (_stateStreamCtrl case final ctrl? when ctrl.hasListener) {
                ctrl.addError(error);
              }
            },
          );
        },
      );
    }

    return _stateStreamCtrl!.stream;
  }

  /// Request for amplitude at given [interval].
  Stream<Amplitude> onAmplitudeChanged(Duration interval) {
    _amplitudeStreamCtrl ??= StreamController<Amplitude>.broadcast();

    _amplitudeTimerInterval = interval;
    _startAmplitudeTimer();

    return _amplitudeStreamCtrl!.stream;
  }

  /// iOS platform specific methods.
  ///
  /// Returns [null] when not on iOS platform.
  RecordIos? get ios => _platform.getIos(_recorderId);

  /// Recovers a recording from persistent storage (Web only).
  ///
  /// On Web, returns the complete WAV file as bytes reconstructed from IndexedDB.
  /// On other platforms, throws [UnimplementedError] as recordings are stored in the filesystem.
  ///
  /// This is useful for crash recovery on Web - if the app crashed during recording,
  /// you can recover the audio that was saved to IndexedDB and get it as a complete
  /// WAV file ready to upload or process.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   final wavBytes = await recorder.recoverRecording('recording_123');
  ///   if (wavBytes != null) {
  ///     // Upload the complete WAV file
  ///     await uploadWavFile(wavBytes);
  ///   }
  /// } on UnimplementedError {
  ///   // Not on web - use filesystem directly
  ///   final file = File('recording_123.wav');
  ///   if (await file.exists()) {
  ///     await uploadFile(file);
  ///   }
  /// }
  /// ```
  Future<Uint8List?> recoverRecording(String path) {
    return _platform.recoverRecording(path);
  }

  /// Deletes a recording from persistent storage (Web only).
  ///
  /// Use this to clean up stored chunks after successful recovery
  /// or if the user chooses to discard the pending recording.
  ///
  /// On other platforms, throws [UnimplementedError] as this is web-specific functionality.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await recorder.deleteRecording('recording_123');
  /// } on UnimplementedError {
  ///   // Not on web - delete from filesystem
  ///   await File('recording_123.wav').delete();
  /// }
  /// ```
  Future<void> deleteRecording(String path) {
    return _platform.deleteRecording(path);
  }

  Future<void> _updateAmplitudeAtInterval() async {
    Future<bool> shouldUpdate() async {
      var result = _amplitudeStreamCtrl != null;
      result &= !(_amplitudeStreamCtrl?.isClosed ?? true);
      result &= _amplitudeStreamCtrl?.hasListener ?? false;
      result &= _amplitudeTimer?.isActive ?? false;

      return result && await isRecording();
    }

    if (await shouldUpdate()) {
      final amplitude = await getAmplitude();
      _amplitudeStreamCtrl?.add(amplitude);
    }
  }

  void _startAmplitudeTimer() {
    _amplitudeTimer?.cancel();

    if (_amplitudeStreamCtrl == null) return;

    _amplitudeTimer = Timer.periodic(
      _amplitudeTimerInterval,
      (timer) => _updateAmplitudeAtInterval(),
    );
  }

  Future<void> _stopRecordStream() async {
    await _recordStreamSubscription?.cancel();
    await _recordStreamCtrl?.close();
    _recordStreamCtrl = null;
  }

  /// Utility method to get PCM data as signed 16 bits integers.
  List<int> convertBytesToInt16(Uint8List bytes, [endian = Endian.little]) {
    final values = <int>[];

    final data = ByteData.view(bytes.buffer);

    for (var i = 0; i < bytes.length; i += 2) {
      int short = data.getInt16(i, endian);
      values.add(short);
    }

    return values;
  }

  Future<T> _safeCall<T>(Future<T> Function() fn) async {
    await _semaphore.acquire();
    try {
      return await fn();
    } finally {
      _semaphore.release();
    }
  }
}

/// A class that represents a semaphore.
class _Semaphore {
  final int maxCount = 1;

  int _counter = 0;
  final _waitQueue = Queue<Completer>();

  /// Acquires a permit from this semaphore, asynchronously blocking until one
  /// is available.
  Future acquire() {
    var completer = Completer();
    if (_counter + 1 <= maxCount) {
      _counter++;
      completer.complete();
    } else {
      _waitQueue.add(completer);
    }
    return completer.future;
  }

  /// Releases a permit, returning it to the semaphore.
  void release() {
    if (_counter == 0) {
      throw StateError("Unable to release semaphore.");
    }
    _counter--;
    if (_waitQueue.isNotEmpty) {
      _counter++;
      var completer = _waitQueue.removeFirst();
      completer.complete();
    }
  }
}
