import AVFoundation
import CoreMedia
import Foundation
import Flutter
import os.log

class RecorderDualDelegate: NSObject, AudioRecordingStreamDelegate {
  var config: RecordConfig?

  private var audioEngine: AVAudioEngine?
  private var amplitude: Float = -160.0
  private let bus = 0
  private let manageAudioSession: Bool
  private var onPause: () -> ()
  private var onStop: () -> ()

  private let basePath: String
  private var m4aWriter: AVAssetWriter?
  private var m4aInput: AVAssetWriterInput?
  private var m4aError: String?
  private var wavWriter: WavFileWriter?
  private var wavError: String?
  private var currentFramePosition: Int64 = 0
  private var pcmFormat: AVAudioFormat?

  init(basePath: String, manageAudioSession: Bool, onPause: @escaping () -> (), onStop: @escaping () -> ()) {
    self.basePath = basePath
    self.manageAudioSession = manageAudioSession
    self.onPause = onPause
    self.onStop = onStop
  }

  func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
    os_log("🔵 RecorderDualDelegate.start: config=%dHz, %dch", log: .default, type: .info, config.sampleRate, config.numChannels)
    let audioEngine = AVAudioEngine()

    try initAVAudioSession(config: config, manageAudioSession: manageAudioSession)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)

    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    os_log("🔵 srcFormat=%fHz, %dch", log: .default, type: .info, srcFormat.sampleRate, srcFormat.channelCount)

    // Interleaved PCM for WAV, streaming, and M4A
    guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(config.sampleRate), channels: AVAudioChannelCount(config.numChannels), interleaved: true) else {
      throw RecorderError.error(message: "Failed to start recording", details: "Unsupported PCM format")
    }
    
    os_log("🔵 pcmFormat=%fHz, %dch, interleaved=%d", log: .default, type: .info, pcmFormat.sampleRate, pcmFormat.channelCount, pcmFormat.isInterleaved)
    
    // Store format for M4A encoding
    self.pcmFormat = pcmFormat

    guard let pcmConverter = AVAudioConverter(from: srcFormat, to: pcmFormat) else {
      throw RecorderError.error(message: "Failed to start recording", details: "PCM conversion is not possible.")
    }
    print("🔵 RecorderDualDelegate.start: converter created")

    // WAV writer
    print("🔵 RecorderDualDelegate.start: creating WAV writer at \(basePath).wav")
    do {
      wavWriter = try WavFileWriter(path: basePath + ".wav", sampleRate: config.sampleRate, channels: config.numChannels)
      print("🔵 RecorderDualDelegate.start: WAV writer created")
    } catch {
      print("🔴 RecorderDualDelegate.start: WAV writer failed: \(error)")
      wavError = error.localizedDescription
      wavWriter = nil
    }

    // M4A writer
    print("🔵 RecorderDualDelegate.start: creating M4A writer")
    do {
      let m4aFilePath = basePath + ".m4a"
      // Delete existing file if it exists
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: m4aFilePath) {
        try fileManager.removeItem(atPath: m4aFilePath)
      }
      
      let url = URL(fileURLWithPath: m4aFilePath)
      let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
      
      // AAC settings
      // Note: We must explicitly specify the encoder settings to match our PCM input
      // Without bitrate, the encoder may make incorrect assumptions
      let bitRate = config.sampleRate * config.numChannels  // ~16kbps for 16kHz mono
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderBitRateKey: bitRate
      ]
      
      print("🔵 RecorderDualDelegate.start: M4A settings - sampleRate=\(config.sampleRate), channels=\(config.numChannels), bitRate=\(bitRate)")
      
      // Create source format hint from pcmFormat
      // This tells the encoder the exact format of incoming PCM data
      guard let sourceFormatDesc = pcmFormat.formatDescription as? CMAudioFormatDescription else {
        throw RecorderError.error(message: "Failed to get PCM format description", details: "Cannot create format description from AVAudioFormat")
      }
      
      print("🔵 RecorderDualDelegate.start: Source format description created")
      if let sourceAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatDesc) {
        print("  ASBD: \(sourceAsbd.pointee.mSampleRate)Hz, \(sourceAsbd.pointee.mChannelsPerFrame)ch, \(sourceAsbd.pointee.mBytesPerFrame) bytes/frame")
      }
      
      // Initialize AVAssetWriterInput with sourceFormatHint
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: sourceFormatDesc)
      input.expectsMediaDataInRealTime = true
      
      print("🔵 RecorderDualDelegate.start: M4A input created")
      print("🔵 RecorderDualDelegate.start: Input sourceFormatHint set: \(String(describing: input.sourceFormatHint))")
      
      guard writer.canAdd(input) else {
        throw RecorderError.error(message: "Cannot add input to M4A writer", details: "Writer rejected input")
      }
      
      writer.add(input)
      writer.startWriting()
      
      guard writer.status != .failed else {
        throw RecorderError.error(message: "Failed to start M4A writer", details: writer.error?.localizedDescription ?? "Unknown error")
      }
      
      writer.startSession(atSourceTime: .zero)
      m4aWriter = writer
      m4aInput = input
      print("🔵 RecorderDualDelegate.start: M4A writer created successfully, status=\(writer.status.rawValue)")
    } catch let recError as RecorderError {
      switch recError {
      case .error(let message, let details):
        m4aError = details != nil ? "\(message): \(details!)" : message
      }
      print("🔴 RecorderDualDelegate.start: M4A writer failed: \(m4aError ?? "unknown")")
      m4aWriter = nil
      m4aInput = nil
    } catch {
      m4aError = error.localizedDescription
      print("🔴 RecorderDualDelegate.start: M4A writer failed: \(error)")
      m4aWriter = nil
      m4aInput = nil
    }

    print("🔵 RecorderDualDelegate.start: installing tap")
    audioEngine.inputNode.installTap(onBus: bus, bufferSize: AVAudioFrameCount(config.streamBufferSize ?? 1024), format: srcFormat) { (buffer, time) -> Void in
      // Convert to PCM 16
      let inputCallback: AVAudioConverterInputBlock = { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }
      // Calculate proper output capacity based on sample rate conversion
      // frameLength is already in frames, so we only need the sample rate ratio
      let capacity = (UInt32(pcmFormat.sampleRate) * buffer.frameLength) / UInt32(buffer.format.sampleRate)
      guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else {
        print("🔴 RecorderDualDelegate.tap: failed to create converted buffer")
        return
      }
      var error: NSError? = nil
      let inputStatus = pcmConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
      if error != nil {
        print("🔴 RecorderDualDelegate.tap: conversion error: \(error!)")
        return
      }
      
      if self.currentFramePosition == 0 {
        os_log("🟢 FIRST BUFFER - Input: %d frames at %fHz", log: .default, type: .info, buffer.frameLength, buffer.format.sampleRate)
        os_log("🟢 FIRST BUFFER - Output: %d frames at %fHz", log: .default, type: .info, convertedBuffer.frameLength, pcmFormat.sampleRate)
        os_log("🟢 FIRST BUFFER - Capacity: %d, actual: %d", log: .default, type: .info, capacity, convertedBuffer.frameLength)
      }

      // Calculate actual byte count from converted frames
      let actualByteCount = Int(convertedBuffer.frameLength) * Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)

      // Extract Int16 samples and update amplitude
      let buffer = convertedBuffer.audioBufferList.pointee.mBuffers
      if let mData = buffer.mData {
        let sampleCount = actualByteCount / 2  // 2 bytes per Int16 sample
        let int16Pointer = mData.bindMemory(to: Int16.self, capacity: sampleCount)
        let samples = Array(UnsafeBufferPointer(start: int16Pointer, count: sampleCount))
        self.updateAmplitude(samples)
      }

      // Stream PCM (interleaved)
      if let eventSink = recordEventHandler.eventSink {
        if let channelData = convertedBuffer.int16ChannelData {
          let channelDataPointer = channelData.pointee
          let samples = stride(from: 0,
                               to: Int(convertedBuffer.frameLength),
                               by: convertedBuffer.stride).map{ channelDataPointer[$0] }
          
          let bytes = Data(self.convertInt16toUInt8(samples))
          
          DispatchQueue.main.async {
            eventSink(FlutterStandardTypedData(bytes: bytes))
          }
        }
      }

      // Write WAV (interleaved)
      if let w = self.wavWriter, self.wavError == nil {
        let buffer = convertedBuffer.audioBufferList.pointee.mBuffers
        if let mData = buffer.mData {
          do {
            try w.writeRaw(bytes: mData, length: actualByteCount)
          } catch {
            self.wavError = error.localizedDescription
          }
        }
      }

      // Write M4A - use interleaved PCM directly
      if let input = self.m4aInput, let writer = self.m4aWriter, self.m4aError == nil {
        if input.isReadyForMoreMediaData {
          // CRITICAL: Use the actual PCM sample rate for the timescale, not the source format
          let pts = CMTimeMake(value: self.currentFramePosition, timescale: Int32(pcmFormat.sampleRate))
          if let sb = convertedBuffer.toCMSampleBuffer(presentationTime: pts) {
            if self.currentFramePosition == 0 {
              print("🟢 RecorderDualDelegate.tap: First M4A sample buffer")
              print("  pts: \(pts.value)/\(pts.timescale) = \(CMTimeGetSeconds(pts))s")
              print("  frameLength: \(convertedBuffer.frameLength)")
              print("  duration: \(CMTimeGetSeconds(CMSampleBufferGetDuration(sb)))s")
            }
            let success = input.append(sb)
            if !success {
              self.m4aError = "Failed to append sample buffer"
              if writer.status == .failed {
                self.m4aError = writer.error?.localizedDescription ?? "Writer failed"
                print("🔴 RecorderDualDelegate.tap: M4A append failed, writer.status=\(writer.status.rawValue), error=\(writer.error?.localizedDescription ?? "nil")")
              } else {
                print("🔴 RecorderDualDelegate.tap: M4A append returned false but writer status is \(writer.status.rawValue)")
              }
            }
          } else {
            self.m4aError = "Failed to create CMSampleBuffer"
            print("🔴 RecorderDualDelegate.tap: Failed to create CMSampleBuffer")
          }
        } else {
          // Only print this once
          if self.m4aError == nil {
            print("🔴 RecorderDualDelegate.tap: M4A input not ready for more data")
          }
        }
      }

      // Advance frame position for timestamps (in PCM sample rate units)
      self.currentFramePosition += Int64(convertedBuffer.frameLength)
    }

    print("🔵 RecorderDualDelegate.start: preparing audio engine")
    audioEngine.prepare()
    print("🔵 RecorderDualDelegate.start: starting audio engine")
    try audioEngine.start()
    self.audioEngine = audioEngine
    self.config = config
    print("🔵 RecorderDualDelegate.start: ✅ COMPLETED SUCCESSFULLY")
  }

  func stopDual(completion: @escaping (_ m4aPath: String?, _ wavPath: String?, _ m4aError: String?, _ wavError: String?) -> ()) {
    audioEngine?.inputNode.removeTap(onBus: bus)
    audioEngine?.stop()
    audioEngine = nil

    let totalFrames = self.currentFramePosition
    let pcmSampleRate = self.pcmFormat?.sampleRate ?? 0
    let expectedDuration = Double(totalFrames) / pcmSampleRate
    os_log("🟢 STOP: Recorded %lld frames at %fHz = %f seconds", log: .default, type: .info, totalFrames, pcmSampleRate, expectedDuration)

    var m4aPath: String? = nil
    if let writer = m4aWriter, let input = m4aInput {
      input.markAsFinished()
      writer.finishWriting {
        // Check writer status after async completion
        if writer.status == .failed {
          self.m4aError = writer.error?.localizedDescription ?? "Unknown error"
        } else if writer.status == .completed {
          m4aPath = self.basePath + ".m4a"
        }
        
        // Continue with completion after writer finishes
        do { try self.wavWriter?.finish() } catch { self.wavError = error.localizedDescription }
        let wavPath = (self.wavWriter != nil) ? self.basePath + ".wav" : nil
        self.wavWriter = nil
        self.m4aWriter = nil
        self.m4aInput = nil

        self.onStop()
        completion(m4aPath, wavPath, self.m4aError, self.wavError)
      }
    } else {
      // No M4A writer, just finish WAV
      do { try wavWriter?.finish() } catch { wavError = error.localizedDescription }
      let wavPath = (wavWriter != nil) ? basePath + ".wav" : nil
      wavWriter = nil
      m4aWriter = nil
      m4aInput = nil

      onStop()
      completion(m4aPath, wavPath, m4aError, wavError)
    }
  }

  // Protocol requirement: stop(completionHandler:)
  func stop(completionHandler: @escaping (String?) -> ()) {
    stopDual { _, _, _, _ in
      completionHandler(nil)
    }
  }

  private func updateAmplitude(_ samples: [Int16]) {
    var maxSample: Float = -160.0
    
    for sample in samples {
      let curSample = abs(Float(sample))
      if curSample > maxSample {
        maxSample = curSample
      }
    }
    
    amplitude = 20 * (log(maxSample / 32767.0) / log(10))
  }
  
  private func convertInt16toUInt8(_ samples: [Int16]) -> [UInt8] {
    var bytes: [UInt8] = []
    
    for sample in samples {
      bytes.append(UInt8(sample & 0x00ff))
      bytes.append(UInt8(sample >> 8 & 0x00ff))
    }
    
    return bytes
  }
  
  // Reuse voice processing toggles from stream delegate
  private func setVoiceProcessing(echoCancel: Bool, autoGain: Bool, audioEngine: AVAudioEngine) throws {
    if #available(iOS 13.0, *) {
      do {
        try audioEngine.inputNode.setVoiceProcessingEnabled(echoCancel)
        audioEngine.inputNode.isVoiceProcessingAGCEnabled = autoGain
      } catch {
        throw RecorderError.error(
          message: "Failed to setup voice processing",
          details: "Echo cancel error: \(error)"
        )
      }
    }
  }

  func pause() { audioEngine?.pause(); onPause() }
  func resume() throws { try audioEngine?.start() }
  func cancel() throws { stop { _ in } }
  func getAmplitude() -> Float { return amplitude }
  func dispose() { stop { _ in } }
}

class WavFileWriter {
  private let fh: FileHandle
  private let sampleRate: Int
  private let channels: Int
  private var bytesWritten: Int = 0

  init(path: String, sampleRate: Int, channels: Int) throws {
    self.sampleRate = sampleRate
    self.channels = channels
    FileManager.default.createFile(atPath: path, contents: nil)
    fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try writeHeaderPlaceholder()
  }

  func write(int16Pointer: UnsafePointer<Int16>, frameCount: Int) throws {
    var bytes = [UInt8](repeating: 0, count: frameCount * channels * 2)
    var idx = 0
    for i in 0..<frameCount {
      let s = int16Pointer[i]
      bytes[idx] = UInt8(s & 0x00ff); bytes[idx+1] = UInt8((s >> 8) & 0x00ff)
      idx += 2
    }
    try fh.write(contentsOf: Data(bytes))
    bytesWritten += bytes.count
  }

  func writeRaw(bytes: UnsafeRawPointer, length: Int) throws {
    let data = Data(bytes: bytes, count: length)
    try fh.write(contentsOf: data)
    bytesWritten += length
  }

  func finish() throws {
    try fh.synchronize()
    try fh.seek(toOffset: 0)
    let header = buildHeader(fileSize: 44 + bytesWritten)
    try fh.write(contentsOf: header)
    try fh.close()
  }

  private func writeHeaderPlaceholder() throws {
    // Write a valid header with maximum size for crash recovery
    // If the app crashes, the file will still be readable up to the data written
    // Audio players stop at EOF even if header indicates larger size
    let maxDataSize = 0x7FFFFFFF // ~2GB max for standard WAV
    let header = buildHeader(fileSize: 44 + maxDataSize)
    try fh.write(contentsOf: header)
  }

  private func buildHeader(fileSize: Int) -> Data {
    var data = Data(capacity: 44)
    func putUInt32LE(_ v: UInt32) {
      let le = v.littleEndian
      data.append(contentsOf: [
        UInt8(truncatingIfNeeded: le >> 0),
        UInt8(truncatingIfNeeded: le >> 8),
        UInt8(truncatingIfNeeded: le >> 16),
        UInt8(truncatingIfNeeded: le >> 24),
      ])
    }
    func putUInt16LE(_ v: UInt16) {
      let le = v.littleEndian
      data.append(contentsOf: [
        UInt8(truncatingIfNeeded: le >> 0),
        UInt8(truncatingIfNeeded: le >> 8),
      ])
    }

    data.append("RIFF".data(using: .ascii)!)
    putUInt32LE(UInt32(fileSize - 8))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    putUInt32LE(16)
    putUInt16LE(1) // PCM
    putUInt16LE(UInt16(channels))
    putUInt32LE(UInt32(sampleRate))
    let byteRate = sampleRate * channels * 2
    putUInt32LE(UInt32(byteRate))
    putUInt16LE(UInt16(channels * 2))
    putUInt16LE(16)
    data.append("data".data(using: .ascii)!)
    putUInt32LE(UInt32(fileSize - 44))

    return data
  }
}

