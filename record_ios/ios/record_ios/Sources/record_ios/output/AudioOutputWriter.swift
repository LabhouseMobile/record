import AVFoundation
import CoreMedia

/// Represents a single output destination for audio recording.
/// Each writer handles its own lifecycle, errors, and output path.
protocol AudioOutputWriter {
  /// Initialize and start the output writer.
  /// - Parameter pcmFormat: The PCM audio format that will be written
  /// - Throws: If initialization fails
  func start(pcmFormat: AVAudioFormat) throws
  
  /// Write a buffer of PCM audio data.
  /// This method should be fail-safe - errors should be stored internally
  /// and not thrown to avoid stopping other outputs.
  /// - Parameters:
  ///   - buffer: PCM audio buffer to write
  ///   - framePosition: Current frame position for timestamping
  func write(buffer: AVAudioPCMBuffer, framePosition: Int64)
  
  /// Stop writing and finalize the output.
  /// - Parameter completion: Called after stopping is complete
  func stop(completion: @escaping () -> Void)
  
  /// Release any resources held by this writer.
  func release()
  
  /// Get the output path if writing was successful, nil otherwise.
  func getOutputPath() -> String?
  
  /// Get any error message that occurred during writing.
  func getError() -> String?
}

