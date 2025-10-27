import 'dart:typed_data';

import 'package:universal_html/html.dart' as html;

import 'encoder.dart';

class PcmEncoder implements Encoder {
  List<int> _dataViews = []; // Uint8List

  @override
  void encode(Int16List buffer) {
    _dataViews.addAll(buffer.buffer.asUint8List());
  }

  @override
  html.Blob finish() {
    final blob = html.Blob(
      [Uint8List.fromList(_dataViews)],
      'audio/pcm',
    );

    cleanup();

    return blob;
  }

  @override
  void cleanup() => _dataViews = [];
}
