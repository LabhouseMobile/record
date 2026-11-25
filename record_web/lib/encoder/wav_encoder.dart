import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'encoder.dart';

// Assumes bit depth to int16
class WavEncoder implements Encoder {
  final int sampleRate;
  final int numChannels;
  int _numSamples = 0;
  List<Uint8List> _parts = [];

  WavEncoder({required this.sampleRate, required this.numChannels});

  /// Keeps a reference to [buffer] until [finish]: callers must not reuse it.
  @override
  void encode(Int16List buffer) {
    _parts.add(
      buffer.buffer.asUint8List(buffer.offsetInBytes, buffer.lengthInBytes),
    );
    _numSamples += buffer.length;
  }

  @override
  web.Blob finish() {
    final dataSize = numChannels * _numSamples * 2;
    final view = ByteData(44);

    view.setString(0, 'RIFF');
    view.setUint32(4, 36 + dataSize, Endian.little);
    view.setString(8, 'WAVE');
    view.setString(12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, 1, Endian.little);
    view.setUint16(22, numChannels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * numChannels * 2, Endian.little);
    view.setUint16(32, numChannels * 2, Endian.little);
    view.setUint16(34, 16, Endian.little);
    view.setString(36, 'data');
    view.setUint32(40, dataSize, Endian.little);

    final blob = web.Blob(
      <JSUint8Array>[
        view.buffer.asUint8List().toJS,
        for (final part in _parts) part.toJS,
      ].toJS,
      web.BlobPropertyBag(type: 'audio/wav'),
    );

    cleanup();

    return blob;
  }

  @override
  void cleanup() => _parts = [];
}

extension ByteDataExt on ByteData {
  void setString(int offset, String str) {
    final len = str.length;

    for (var i = 0; i < len; ++i) {
      setUint8(offset + i, str.codeUnitAt(i));
    }
  }
}
