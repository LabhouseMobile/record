import 'dart:typed_data';
import 'package:web/web.dart' as web;

abstract class Encoder {
  /// Implementations may keep a reference to [buffer] until [finish], so callers must not reuse it.
  void encode(Int16List buffer);

  web.Blob finish();

  void cleanup();
}
