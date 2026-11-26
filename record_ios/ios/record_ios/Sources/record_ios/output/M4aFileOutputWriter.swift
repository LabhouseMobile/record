import AVFoundation
import CoreMedia
import Foundation

/// Output writer that encodes PCM audio to M4A/AAC format.
class M4aFileOutputWriter: AudioOutputWriter {
  private let outputPath: String
  private let targetBitRate: Int
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var errorMessage: String?
  private var pcmFormat: AVAudioFormat?
  private var receivedFrames: Int64 = 0
  private var droppedFrames: Int64 = 0
  /// Audio dropped because the input was not ready for more data, set at stop.
  private(set) var droppedMs = 0
  private let maxDroppedMs = 5000
  
  init(outputPath: String, bitRate: Int) {
    self.outputPath = outputPath
    self.targetBitRate = bitRate
  }
  
  func start(pcmFormat: AVAudioFormat) throws {
    do {
      try startWriter(pcmFormat: pcmFormat)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  private func startWriter(pcmFormat: AVAudioFormat) throws {
    self.pcmFormat = pcmFormat
    
    // Delete existing file if it exists
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputPath) {
      try fileManager.removeItem(atPath: outputPath)
    }
    
    let url = URL(fileURLWithPath: outputPath)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    
    let sampleRate = Int(pcmFormat.sampleRate)
    let channels = Int(pcmFormat.channelCount)
    
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: targetBitRate
    ]
    
    // Create source format hint from pcmFormat
    guard let sourceFormatDesc = pcmFormat.formatDescription as? CMAudioFormatDescription else {
      throw RecorderError.error(
        message: "Failed to get PCM format description",
        details: "Cannot create format description from AVAudioFormat"
      )
    }
    
    // Initialize AVAssetWriterInput with sourceFormatHint
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: settings,
      sourceFormatHint: sourceFormatDesc
    )
    input.expectsMediaDataInRealTime = true
    
    guard writer.canAdd(input) else {
      throw RecorderError.error(
        message: "Cannot add input to M4A writer",
        details: "Writer rejected input"
      )
    }
    
    writer.add(input)
    writer.startWriting()
    
    guard writer.status != .failed else {
      throw RecorderError.error(
        message: "Failed to start M4A writer",
        details: writer.error?.localizedDescription ?? "Unknown error"
      )
    }
    
    writer.startSession(atSourceTime: .zero)
    self.writer = writer
    self.input = input
  }
  
  func write(buffer: AVAudioPCMBuffer, framePosition: Int64) {
    guard errorMessage == nil,
          let input = input,
          let writer = writer,
          let pcmFormat = pcmFormat else { return }
    
    receivedFrames += Int64(buffer.frameLength)
    guard input.isReadyForMoreMediaData else {
      droppedFrames += Int64(buffer.frameLength)
      return
    }
    
    let pts = CMTimeMake(value: framePosition, timescale: Int32(pcmFormat.sampleRate))
    
    guard let sampleBuffer = buffer.toCMSampleBuffer(presentationTime: pts) else {
      if errorMessage == nil {
        errorMessage = "Failed to create CMSampleBuffer"
      }
      return
    }
    
    let success = input.append(sampleBuffer)
    if !success {
      if writer.status == .failed {
        errorMessage = writer.error?.localizedDescription ?? "Writer failed"
      } else if errorMessage == nil {
        errorMessage = "Failed to append sample buffer"
      }
    }
  }
  
  func stop(completion: @escaping () -> Void) {
    guard let writer = writer, let input = input else {
      completion()
      return
    }
    
    input.markAsFinished()
    writer.finishWriting { [weak self] in
      guard let self = self else {
        completion()
        return
      }
      
      if writer.status == .failed {
        self.errorMessage = writer.error?.localizedDescription ?? "Unknown error"
      }
      
      self.droppedMs = self.milliseconds(self.droppedFrames)
      // More than 5 s dropped leaves holes in the M4A: fail it so the WAV is used
      if self.errorMessage == nil, self.droppedMs > self.maxDroppedMs {
        self.errorMessage = "M4A writer dropped \(self.droppedMs) ms of \(self.milliseconds(self.receivedFrames)) ms"
      }
      
      completion()
    }
  }
  
  private func milliseconds(_ frames: Int64) -> Int {
    guard let sampleRate = pcmFormat?.sampleRate, sampleRate > 0 else { return 0 }
    return Int(Double(frames) * 1000 / sampleRate)
  }
  
  func release() {
    writer = nil
    input = nil
    pcmFormat = nil
  }
  
  func getOutputPath() -> String? {
    return errorMessage == nil ? outputPath : nil
  }
  
  var configuredPath: String {
    return outputPath
  }
  
  func getError() -> String? {
    return errorMessage
  }
}

