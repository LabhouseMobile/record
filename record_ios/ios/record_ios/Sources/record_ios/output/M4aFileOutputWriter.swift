import AVFoundation
import CoreMedia
import Foundation

/// Output writer that encodes PCM audio to M4A/AAC format.
/// Uses a queue-and-drain pattern to avoid dropping frames when the AAC encoder
/// buffer is full (isReadyForMoreMediaData == false), e.g. under CPU/memory pressure.
class M4aFileOutputWriter: AudioOutputWriter {
  private let outputPath: String
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var errorMessage: String?
  private var pcmFormat: AVAudioFormat?
  private let drainQueue = DispatchQueue(label: "M4aFileOutputWriter.drain")
  private var pendingSampleBuffers: [CMSampleBuffer] = []

  init(outputPath: String) {
    self.outputPath = outputPath
  }
  
  func start(pcmFormat: AVAudioFormat) throws {
    self.pcmFormat = pcmFormat
    
    // Delete existing file if it exists
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputPath) {
      try fileManager.removeItem(atPath: outputPath)
    }
    
    let url = URL(fileURLWithPath: outputPath)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    
    // AAC settings
    let sampleRate = Int(pcmFormat.sampleRate)
    let channels = Int(pcmFormat.channelCount)
    let bitRate = sampleRate * channels  // ~16kbps for 16kHz mono
    
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: bitRate
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

    let pts = CMTimeMake(value: framePosition, timescale: Int32(pcmFormat.sampleRate))

    guard let sampleBuffer = buffer.toCMSampleBuffer(presentationTime: pts) else {
      if errorMessage == nil {
        errorMessage = "Failed to create CMSampleBuffer"
      }
      return
    }

    drainQueue.async { [weak self] in
      self?.enqueueAndDrain(sampleBuffer: sampleBuffer)
    }
  }

  private func enqueueAndDrain(sampleBuffer: CMSampleBuffer) {
    guard errorMessage == nil,
          let input = input,
          let writer = writer else { return }

    pendingSampleBuffers.append(sampleBuffer)
    drainPendingBuffers()
  }

  private func drainPendingBuffers() {
    guard errorMessage == nil,
          let input = input,
          let writer = writer else { return }

    while !pendingSampleBuffers.isEmpty && input.isReadyForMoreMediaData && writer.status != .failed {
      let sampleBuffer = pendingSampleBuffers.removeFirst()
      let success = input.append(sampleBuffer)
      if !success {
        if writer.status == .failed {
          errorMessage = writer.error?.localizedDescription ?? "Writer failed"
        } else if errorMessage == nil {
          errorMessage = "Failed to append sample buffer"
        }
        pendingSampleBuffers.insert(sampleBuffer, at: 0)
        return
      }
    }
  }
  
  func stop(completion: @escaping () -> Void) {
    guard writer != nil, input != nil else {
      completion()
      return
    }

    drainQueue.async { [weak self] in
      guard let self = self,
            let writer = self.writer,
            let input = self.input else {
        completion()
        return
      }

      self.drainPendingBuffers()
      input.markAsFinished()
      writer.finishWriting { [weak self] in
        guard let self = self else {
          completion()
          return
        }
        if writer.status == .failed {
          self.errorMessage = writer.error?.localizedDescription ?? "Unknown error"
        }
        self.pendingSampleBuffers.removeAll()
        completion()
      }
    }
  }
  
  func release() {
    drainQueue.sync {
      writer = nil
      input = nil
      pcmFormat = nil
      pendingSampleBuffers.removeAll()
    }
  }
  
  func getOutputPath() -> String? {
    return errorMessage == nil ? outputPath : nil
  }
  
  func getError() -> String? {
    return errorMessage
  }
}

