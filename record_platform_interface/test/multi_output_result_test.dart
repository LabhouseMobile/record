import 'package:flutter_test/flutter_test.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

void main() {
  group('MultiOutputResult.fromMap', () {
    test('a missing m4aDroppedMs key gives null', () {
      final result = MultiOutputResult.fromMap({
        'm4aPath': '/rec.m4a',
        'wavPath': '/rec.wav',
        'm4aError': null,
        'wavError': null,
      });

      expect(result.m4aDroppedMs, isNull);
      expect(result.successfulPaths, ['/rec.m4a', '/rec.wav']);
    });

    test('a failed M4A leaves only the WAV as a successful path', () {
      final result = MultiOutputResult.fromMap({
        'm4aPath': null,
        'wavPath': '/rec.wav',
        'm4aError': 'M4A writer dropped more than 5000 ms',
        'wavError': null,
        'm4aDroppedMs': 48000,
      });

      expect(result.successfulPaths, ['/rec.wav']);
      expect(result.m4aDroppedMs, 48000);
      expect(result.hasError, isTrue);
    });

    test('round-trips through toMap', () {
      const original = MultiOutputResult(
        wavPath: '/rec.wav',
        m4aError: 'M4A writer dropped more than 5000 ms',
        m4aDroppedMs: 48000,
      );

      final copy = MultiOutputResult.fromMap(original.toMap());

      expect(copy.m4aPath, isNull);
      expect(copy.wavPath, '/rec.wav');
      expect(copy.m4aError, 'M4A writer dropped more than 5000 ms');
      expect(copy.wavError, isNull);
      expect(copy.m4aDroppedMs, 48000);
    });
  });
}
