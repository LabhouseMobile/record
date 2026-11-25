@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record_web/encoder/wav_encoder.dart';

void main() {
  group('WavEncoder', () {
    test(
      'writes a 16-bit PCM header followed by every sample in order',
      () async {
        final encoder = WavEncoder(sampleRate: 16000, numChannels: 1)
          ..encode(Int16List.fromList([1, -2, 3]))
          ..encode(Int16List.fromList([32767, -32768]));

        final blob = encoder.finish();
        final bytes = (await blob.arrayBuffer().toDart).toDart.asUint8List();
        final header = ByteData.sublistView(bytes, 0, 44);

        expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
        expect(header.getUint32(24, Endian.little), 16000);
        expect(header.getUint32(40, Endian.little), 10);
        expect(bytes.length, 44 + 10);
        expect(Int16List.sublistView(Uint8List.fromList(bytes.sublist(44))), [
          1,
          -2,
          3,
          32767,
          -32768,
        ]);
      },
    );

    test(
      'writes only the bytes of a view, not its whole backing buffer',
      () async {
        final backing = Int16List.fromList([9, 1, 2, 9]);
        final encoder = WavEncoder(sampleRate: 16000, numChannels: 1)
          ..encode(Int16List.sublistView(backing, 1, 3));

        final bytes = (await encoder.finish().arrayBuffer().toDart).toDart
            .asUint8List();

        expect(Int16List.sublistView(Uint8List.fromList(bytes.sublist(44))), [
          1,
          2,
        ]);
      },
    );
  });
}
