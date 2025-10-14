import AVFoundation
import Foundation
import Flutter

/// A recording delegate that supports streaming PCM to Dart while also
/// writing to multiple output files simultaneously using output writers.
class RecorderMultiOutputDelegate: NSObject, AudioRecordingStreamDelegate {
  var config: RecordConfig?
  
  private var audioEngine: AVAudioEngine?
  private var amplitude: Float = -160.0
  private let bus = 0
  private var onPause: () -> ()
  private var onStop: () -> ()
  private let manageAudioSession: Bool
  private var isResuming = false
  private var isInterrupted = false
  private let outputWriters: [AudioOutputWriter]
  private var currentFramePosition: Int64 = 0
  
  init(
    outputWriters: [AudioOutputWriter],
    manageAudioSession: Bool,
    onPause: @escaping () -> (),
    onStop: @escaping () -> ()
  ) {
    self.outputWriters = outputWriters
    self.manageAudioSession = manageAudioSession
    self.onPause = onPause
    self.onStop = onStop
  }
  
  func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
    let audioEngine = AVAudioEngine()
    
    try initAVAudioSession(config: config, manageAudioSession: manageAudioSession)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)
    
    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    
    // Interleaved PCM for streaming and output writers
    guard let pcmFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(config.sampleRate),
      channels: AVAudioChannelCount(config.numChannels),
      interleaved: true
    ) else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Unsupported PCM format"
      )
    }
    
    guard let converter = AVAudioConverter(from: srcFormat, to: pcmFormat) else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "PCM conversion is not possible."
      )
    }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    
    // Initialize all output writers
    for writer in outputWriters {
      do {
        try writer.start(pcmFormat: pcmFormat)
      } catch {
        // Writers track their own errors, continue with others
      }
    }
    
    audioEngine.inputNode.installTap(
      onBus: bus,
      bufferSize: AVAudioFrameCount(config.streamBufferSize ?? 1024),
      format: srcFormat
    ) { (buffer, _) -> Void in
      self.processPCMBuffer(
        buffer: buffer,
        pcmFormat: pcmFormat,
        converter: converter,
        recordEventHandler: recordEventHandler
      )
    }
    
    audioEngine.prepare()
    try audioEngine.start()
    
    self.audioEngine = audioEngine
    
    // Add observers for audio engine configuration changes
    setupAudioEngineObservers()
    
    self.config = config
  }
  
  private func processPCMBuffer(
    buffer: AVAudioPCMBuffer,
    pcmFormat: AVAudioFormat,
    converter: AVAudioConverter,
    recordEventHandler: RecordStreamHandler
  ) {
    // Convert to PCM 16
    let inputCallback: AVAudioConverterInputBlock = { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    
    let capacity = (UInt32(pcmFormat.sampleRate) * buffer.frameLength) / UInt32(buffer.format.sampleRate)
    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else {
      return
    }
    
    var error: NSError? = nil
    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
    if error != nil {
      return
    }
    
    // Extract Int16 samples and update amplitude
    let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
    if let mData = audioBuffer.mData {
      let actualByteCount = Int(convertedBuffer.frameLength) * Int(pcmFormat.streamDescription.pointee.mBytesPerFrame)
      let sampleCount = actualByteCount / 2
      let int16Pointer = mData.bindMemory(to: Int16.self, capacity: sampleCount)
      let samples = Array(UnsafeBufferPointer(start: int16Pointer, count: sampleCount))
      updateAmplitude(samples)
    }
    
    // Stream PCM to Dart
    if let eventSink = recordEventHandler.eventSink {
      if let channelData = convertedBuffer.int16ChannelData {
        let channelDataPointer = channelData.pointee
        let samples = stride(from: 0,
                             to: Int(convertedBuffer.frameLength),
                             by: convertedBuffer.stride).map{ channelDataPointer[$0] }
        
        let bytes = Data(convertInt16toUInt8(samples))
        
        DispatchQueue.main.async {
          eventSink(FlutterStandardTypedData(bytes: bytes))
        }
      }
    }
    
    // Write to all output writers
    for writer in outputWriters {
      writer.write(buffer: convertedBuffer, framePosition: currentFramePosition)
    }
    
    // Advance frame position for timestamps
    currentFramePosition += Int64(convertedBuffer.frameLength)
  }
  
  func stop(completionHandler: @escaping (String?) -> ()) {
    // Remove observers
    removeAudioEngineObservers()
    
    audioEngine?.inputNode.removeTap(onBus: bus)
    audioEngine?.stop()
    audioEngine = nil
    
    // Stop all output writers in order
    let group = DispatchGroup()
    for writer in outputWriters {
      group.enter()
      writer.stop { group.leave() }
    }
    
    group.notify(queue: .main) { [weak self] in
      // Release all writers
      self?.outputWriters.forEach { $0.release() }
      self?.onStop()
      completionHandler(nil)
    }
    
    config = nil
  }
  
  /// Get results from all output writers
  func getOutputResults() -> [String: String?] {
    var results: [String: String?] = [:]
    for writer in outputWriters {
      if let path = writer.getOutputPath() ?? writer.getError() {
        results[path] = writer.getError()
      }
    }
    return results
  }
  
  func pause() {
    isInterrupted = true
    audioEngine?.pause()
    onPause()
  }
  
  func resume() throws {
    guard let engine = audioEngine else {
      throw RecorderError.error(message: "Failed to resume", details: "Audio engine is nil")
    }
    
    isInterrupted = false
    isResuming = true
    
    // Re-prepare the engine after interruption
    engine.prepare()
    try engine.start()
    
    // Reset flag after a short delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      self.isResuming = false
    }
  }
  
  func cancel() throws {
    stop { _ in }
  }
  
  func getAmplitude() -> Float {
    return amplitude
  }
  
  func dispose() {
    stop { _ in }
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
  
  private func setupAudioEngineObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleConfigurationChange),
      name: .AVAudioEngineConfigurationChange,
      object: audioEngine
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMediaServicesReset),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: nil
    )
  }
  
  private func removeAudioEngineObservers() {
    NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: audioEngine)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
  }
  
  @objc private func handleConfigurationChange(notification: Notification) {
    NSLog("[Record] Audio engine configuration changed, interrupted=\(isInterrupted)")
    
    // Don't try to restart during an active interruption (phone call, etc.)
    // The interruption end handler will take care of resuming
    guard !isInterrupted else {
      NSLog("[Record] Skipping restart during interruption")
      return
    }
    
    guard let engine = audioEngine, !engine.isRunning else {
      return
    }
    
    NSLog("[Record] Audio engine stopped after configuration change, attempting restart...")
    
    // Engine stopped, try to restart it
    do {
      engine.prepare()
      try engine.start()
      NSLog("[Record] Successfully restarted audio engine after configuration change")
    } catch {
      NSLog("[Record] Failed to restart audio engine: \(error.localizedDescription)")
      stop { path in }
    }
  }
  
  @objc private func handleRouteChange(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }
    
    NSLog("[Record] Audio route changed: reason=\(reason.rawValue), interrupted=\(isInterrupted), resuming=\(isResuming)")
    
    // Don't try to restart during an active interruption
    guard !isInterrupted else {
      NSLog("[Record] Skipping route change handling during interruption")
      return
    }
    
    // Only restart if we're resuming and the route change caused the engine to stop
    if isResuming, let engine = audioEngine, !engine.isRunning {
      NSLog("[Record] Audio engine stopped due to route change during resume, attempting restart...")
      do {
        engine.prepare()
        try engine.start()
        NSLog("[Record] Successfully restarted audio engine after route change")
      } catch {
        NSLog("[Record] Failed to restart audio engine after route change: \(error.localizedDescription)")
      }
    }
  }
  
  @objc private func handleMediaServicesReset(notification: Notification) {
    NSLog("[Record] Media services were reset, restarting recording...")
    
    // Media services reset requires full restart
    stop { path in }
  }
}

