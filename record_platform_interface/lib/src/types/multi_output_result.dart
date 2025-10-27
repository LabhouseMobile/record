import 'package:universal_html/html.dart' as html;

/// Result from a multi-output recording session.
/// Contains paths and error information for each output destination.
class MultiOutputResult {
  /// Path to the M4A output file, or null if writing failed
  final String? m4aPath;

  /// Path to the WAV output file, or null if writing failed
  final String? wavPath;

  /// Error message from M4A encoding, or null if successful
  final String? m4aError;

  /// Error message from WAV writing, or null if successful
  final String? wavError;

  /// Blob for the M4A output file, or null if writing failed
  final html.Blob? m4aBlob;

  /// Blob for the WAV output file, or null if writing failed
  final html.Blob? wavBlob;

  const MultiOutputResult({
    this.m4aPath,
    this.wavPath,
    this.m4aBlob,
    this.wavBlob,
    this.m4aError,
    this.wavError,
  });

  /// Check if all outputs completed successfully
  bool get isSuccess => m4aError == null && wavError == null;

  /// Check if any output had an error
  bool get hasError => m4aError != null || wavError != null;

  /// Get all successful output paths
  List<String> get successfulPaths {
    final paths = <String>[];
    if (m4aPath != null && m4aError == null) paths.add(m4aPath!);
    if (wavPath != null && wavError == null) paths.add(wavPath!);
    return paths;
  }

  /// Get all error messages
  List<String> get errors {
    final errorList = <String>[];
    if (m4aError != null) errorList.add('M4A: $m4aError');
    if (wavError != null) errorList.add('WAV: $wavError');
    return errorList;
  }

  /// Create from platform method channel response
  factory MultiOutputResult.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const MultiOutputResult();
    }

    return MultiOutputResult(
      m4aPath: map['m4aPath'] as String?,
      wavPath: map['wavPath'] as String?,
      m4aError: map['m4aError'] as String?,
      wavError: map['wavError'] as String?,
      m4aBlob: map['m4aBlob'] as html.Blob?,
      wavBlob: map['wavBlob'] as html.Blob?,
    );
  }

  /// Convert to map for method channel
  Map<String, dynamic> toMap() {
    return {
      'm4aPath': m4aPath,
      'wavPath': wavPath,
      'm4aError': m4aError,
      'wavError': wavError,
      'm4aBlob': m4aBlob,
      'wavBlob': wavBlob,
    };
  }

  @override
  String toString() {
    return '''
MultiOutputResult(
  m4aPath: $m4aPath,
  wavPath: $wavPath,
  m4aError: $m4aError,
  wavError: $wavError,
  m4aBlob: $m4aBlob,
  wavBlob: $wavBlob,
)
''';
  }
}
