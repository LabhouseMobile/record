import AVFoundation
import Foundation

/// Output writer that writes PCM audio directly to a WAV file.
class WavFileOutputWriter: AudioOutputWriter {
  private let outputPath: String
  private var wavWriter: WavFileWriter?
  private var errorMessage: String?
  
  init(outputPath: String) {
    self.outputPath = outputPath
  }
  
  func start(pcmFormat: AVAudioFormat) throws {
    do {
      wavWriter = try WavFileWriter(
        path: outputPath,
        sampleRate: Int(pcmFormat.sampleRate),
        channels: Int(pcmFormat.channelCount)
      )
    } catch {
      errorMessage = error.localizedDescription
      wavWriter = nil
      throw error
    }
  }
  
  func write(buffer: AVAudioPCMBuffer, framePosition: Int64) {
    guard errorMessage == nil, let writer = wavWriter else { return }
    
    let mBuffer = buffer.audioBufferList.pointee.mBuffers
    if let mData = mBuffer.mData {
      let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
      let actualByteCount = Int(buffer.frameLength) * bytesPerFrame
      
      do {
        try writer.writeRaw(bytes: mData, length: actualByteCount)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
  
  func stop(completion: @escaping () -> Void) {
    if let writer = wavWriter, errorMessage == nil {
      do {
        try writer.finish()
      } catch {
        if errorMessage == nil {
          errorMessage = error.localizedDescription
        }
      }
    }
    completion()
  }
  
  func release() {
    wavWriter = nil
  }
  
  func getOutputPath() -> String? {
    return errorMessage == nil ? outputPath : nil
  }
  
  func getError() -> String? {
    return errorMessage
  }
}

/// Simple WAV file writer
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

