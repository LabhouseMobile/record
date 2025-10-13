import AVFoundation
import CoreMedia

extension AVAudioPCMBuffer {
  func toCMSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
    var asbd = format.streamDescription.pointee

    var formatDesc: CMAudioFormatDescription?
    let statusFmt = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                   asbd: &asbd,
                                                   layoutSize: 0,
                                                   layout: nil,
                                                   magicCookieSize: 0,
                                                   magicCookie: nil,
                                                   extensions: nil,
                                                   formatDescriptionOut: &formatDesc)
    if statusFmt != noErr || formatDesc == nil {
      return nil
    }

    // Calculate total data length for all channels
    // Same regardless of interleaved vs non-interleaved - only the layout differs
    let bytesPerSample = Int(format.streamDescription.pointee.mBitsPerChannel / 8)
    let channelCount = Int(format.channelCount)
    let totalDataLength = Int(frameLength) * channelCount * bytesPerSample

    var blockBuffer: CMBlockBuffer?
    let statusBB = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                      memoryBlock: nil,
                                                      blockLength: totalDataLength,
                                                      blockAllocator: kCFAllocatorDefault,
                                                      customBlockSource: nil,
                                                      offsetToData: 0,
                                                      dataLength: totalDataLength,
                                                      flags: 0,
                                                      blockBufferOut: &blockBuffer)
    if statusBB != kCMBlockBufferNoErr { return nil }

    guard let bb = blockBuffer else { return nil }

    // Copy PCM data
    if format.isInterleaved {
      // Interleaved: single buffer
      let buffer = audioBufferList.pointee.mBuffers
      if let mData = buffer.mData {
        let src = mData.assumingMemoryBound(to: UInt8.self)
        CMBlockBufferReplaceDataBytes(with: src, blockBuffer: bb, offsetIntoDestination: 0, dataLength: totalDataLength)
      } else {
        return nil
      }
    } else {
      // Non-interleaved: concatenate all channel buffers
      var offset = 0
      let channelDataLength = Int(frameLength) * bytesPerSample
      let numBuffers = Int(audioBufferList.pointee.mNumberBuffers)
      
      // Access buffers using raw pointer arithmetic
      let buffersPtr = withUnsafePointer(to: audioBufferList.pointee.mBuffers) { $0 }
      let buffers = UnsafeBufferPointer(start: buffersPtr, count: numBuffers)
      
      for buffer in buffers {
        if let mData = buffer.mData {
          let src = mData.assumingMemoryBound(to: UInt8.self)
          CMBlockBufferReplaceDataBytes(with: src, blockBuffer: bb, offsetIntoDestination: offset, dataLength: channelDataLength)
          offset += channelDataLength
        } else {
          return nil
        }
      }
    }

    let duration = CMTime(value: Int64(frameLength), timescale: CMTimeScale(format.sampleRate))
    var timing = CMSampleTimingInfo(duration: duration,
                                    presentationTimeStamp: presentationTime,
                                    decodeTimeStamp: .invalid)

    var sampleBuffer: CMSampleBuffer?
    let statusSB = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                             dataBuffer: bb,
                                             formatDescription: formatDesc!,
                                             sampleCount: CMItemCount(frameLength),
                                             sampleTimingEntryCount: 1,
                                             sampleTimingArray: &timing,
                                             sampleSizeEntryCount: 0,
                                             sampleSizeArray: nil,
                                             sampleBufferOut: &sampleBuffer)
    if statusSB != noErr { return nil }

    return sampleBuffer
  }
}

extension AudioRecordingDelegate {
  func getFileTypeFromSettings(_ settings: [String : Any]) -> AVFileType {
    let formatId = settings[AVFormatIDKey] as! UInt32
    
    switch formatId {
    case kAudioFormatAMR, kAudioFormatAMR_WB:
      return AVFileType.mobile3GPP
    case kAudioFormatLinearPCM:
      return AVFileType.wav
    default:
      return AVFileType.m4a
    }
  }
  
  func getInputSettings(config: RecordConfig) -> [String : Any] {
    let format = AVAudioFormat(
      commonFormat: AVAudioCommonFormat.pcmFormatInt16,
      sampleRate: (config.sampleRate < 48000) ? Double(config.sampleRate) : 48000.0,
      channels: UInt32((config.numChannels > 2) ? 2 : config.numChannels),
      interleaved: false
    )

    return format!.settings
  }

  // https://developer.apple.com/documentation/coreaudiotypes/coreaudiotype_constants/1572096-audio_data_format_identifiers
  func getOutputSettings(config: RecordConfig) throws -> [String : Any] {
    var settings: [String : Any]
    var keepSampleRate = false

    switch config.encoder {
    case AudioEncoder.aacLc.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatMPEG4AAC,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.aacEld.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatMPEG4AAC_ELD_V2,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.aacHe.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatMPEG4AAC_HE_V2,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.amrNb.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatAMR,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: 8000,
        AVNumberOfChannelsKey: config.numChannels,
        AVLinearPCMBitDepthKey: 8,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.amrWb.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatAMR_WB,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.opus.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatOpus,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.flac.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatFLAC,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    case AudioEncoder.pcm16bits.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
      keepSampleRate = true
    case AudioEncoder.wav.rawValue:
      settings = [
        AVFormatIDKey : kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
      keepSampleRate = true
    default:
      settings = [
        AVFormatIDKey : kAudioFormatMPEG4AAC,
        AVEncoderBitRateKey: config.bitRate,
        AVSampleRateKey: config.sampleRate,
        AVNumberOfChannelsKey: config.numChannels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    }
    
    // Check available settings & adjust them if needed
    guard let inFormat = AVAudioFormat(settings: getInputSettings(config: config)) else {
      throw RecorderError.error(message: "Failed to start recording", details: "Input format initialization failure.")
    }
    guard let outFormat = AVAudioFormat(settings: settings) else {
      throw RecorderError.error(message: "Failed to start recording", details: "Output format initialization failure.")
    }
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
      throw RecorderError.error(message: "Failed to start recording", details: "Format conversion isn’t possible. Format or configuration is not supported.")
    }

    if let sampleRate = settings[AVSampleRateKey] as? NSNumber,
       let sampleRates = converter.availableEncodeSampleRates {
      settings[AVSampleRateKey] = nearestValue(values: sampleRates, value: sampleRate, key: "sample rates").floatValue
    } else if !keepSampleRate {
      settings.removeValue(forKey: AVSampleRateKey)
    }
    
    if let bitRate = settings[AVEncoderBitRateKey] as? NSNumber,
       let bitRates = converter.availableEncodeBitRates {
      settings[AVEncoderBitRateKey] = nearestValue(values: bitRates, value: bitRate, key: "bit rates").intValue
    } else {
      settings.removeValue(forKey: AVEncoderBitRateKey)
    }
    
    return settings
  }
  
  private func nearestValue(values: [NSNumber], value: NSNumber, key: String) -> NSNumber {
    // Sometimes converter does not give any good listing
    if values.count == 0 || (values.count == 1 && values[0] == 0) {
      return value
    }
    
    var distance = abs(values[0].floatValue - value.floatValue)
    var idx = 0
    
    for c in 1..<values.count {
      let cdistance = abs(values[c].floatValue - value.floatValue)
      if (cdistance < distance) {
        idx = c
        distance = cdistance
      }
    }
    
    if (values[idx] != value) {
      print("Available \(key): \(values).")
      print("Given \(value) has been adjusted to \(values[idx]).")
    }
    
    return values[idx]
  }
}
