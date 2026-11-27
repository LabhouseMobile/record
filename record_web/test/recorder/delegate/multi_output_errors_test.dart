import 'package:flutter_test/flutter_test.dart';
import 'package:record_web/recorder/delegate/multi_output_errors.dart';

void main() {
  group('wavErrorFor', () {
    test('is null when the WAV was built', () {
      expect(wavErrorFor(hasWav: true, hasCompressed: false), isNull);
    });

    test('is null when the WAV was skipped because the compressed file exists', () {
      expect(wavErrorFor(hasWav: false, hasCompressed: true), isNull);
    });

    test('reports an error when neither output exists', () {
      expect(wavErrorFor(hasWav: false, hasCompressed: false), 'WAV encoding failed or no data');
    });
  });
}
