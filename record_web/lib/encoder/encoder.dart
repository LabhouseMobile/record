import 'dart:typed_data';

import 'package:universal_html/html.dart' as html;

abstract class Encoder {
  void encode(Int16List buffer);

  html.Blob finish();

  void cleanup();
}
