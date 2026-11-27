/// `wavError` of a dual-output stop. Skipping the WAV because the compressed file exists isn't an error.
String? wavErrorFor({required bool hasWav, required bool hasCompressed}) =>
    hasWav || hasCompressed ? null : 'WAV encoding failed or no data';
