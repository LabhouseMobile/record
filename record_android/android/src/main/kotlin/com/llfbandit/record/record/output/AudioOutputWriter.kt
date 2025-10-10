package com.llfbandit.record.record.output

/**
 * Represents a single output destination for audio recording.
 * Each writer handles its own lifecycle, errors, and output path.
 */
interface AudioOutputWriter {
  /**
   * Initialize and start the output writer.
   * Called once before any write operations.
   *
   * @throws Exception if initialization fails
   */
  fun start()

  /**
   * Write a buffer of PCM audio data.
   * This method should be fail-safe - errors should be stored internally
   * and not thrown to avoid stopping other outputs.
   *
   * @param buffer PCM audio data (typically 16-bit samples)
   */
  fun write(buffer: ByteArray)

  /**
   * Stop writing and finalize the output.
   * Called once when recording stops.
   */
  fun stop()

  /**
   * Release any resources held by this writer.
   * Called after stop() to clean up.
   */
  fun release()

  /**
   * Get the output path if writing was successful, null otherwise.
   *
   * @return The file path of the output, or null if failed
   */
  fun getOutputPath(): String?

  /**
   * Get any error message that occurred during writing.
   *
   * @return Error message or null if no error
   */
  fun getError(): String?
}

