import AVFoundation
import Foundation
import Flutter

class RecorderStreamDelegate: NSObject, AudioRecordingStreamDelegate {
  var config: RecordConfig?
  
  private var audioEngine: AVAudioEngine?
  private var amplitude: Float = -160.0
  private let bus = 0
  private var onPause: () -> ()
  private var onStop: () -> ()
  private let manageAudioSession: Bool
  private var isResuming = false
  private var isInterrupted = false
  
  init(manageAudioSession: Bool, onPause: @escaping () -> (), onStop: @escaping () -> ()) {
    self.manageAudioSession = manageAudioSession
    self.onPause = onPause
    self.onStop = onStop
  }

  func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
    let audioEngine = AVAudioEngine()

    try initAVAudioSession(config: config, manageAudioSession: manageAudioSession)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)
    
    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    
    let dstFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(config.sampleRate),
      channels: AVAudioChannelCount(config.numChannels),
      interleaved: true
    )

    guard let dstFormat = dstFormat else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Format is not supported: \(config.sampleRate)Hz - \(config.numChannels) channels."
      )
    }

    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Format conversion is not possible."
      )
    }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

    audioEngine.inputNode.installTap(
      onBus: bus,
      bufferSize: AVAudioFrameCount(config.streamBufferSize ?? 1024),
      format: srcFormat) { (buffer, _) -> Void in

      self.stream(
        buffer: buffer,
        dstFormat: dstFormat,
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
  
  func stop(completionHandler: @escaping (String?) -> ()) {
    // Remove observers
    removeAudioEngineObservers()
    
    if let audioEngine = audioEngine {
      do {
        try setVoiceProcessing(echoCancel: false, autoGain: false, audioEngine: audioEngine)
      } catch {}
    }
    
    audioEngine?.inputNode.removeTap(onBus: bus)
    audioEngine?.stop()
    audioEngine = nil
    
    completionHandler(nil)
    onStop()
    
    config = nil
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
    stop { path in }
  }
  
  func getAmplitude() -> Float {
    return amplitude
  }
  
  private func updateAmplitude(_ samples: [Int16]) {
    var maxSample:Float = -160.0

    for sample in samples {
      let curSample = abs(Float(sample))
      if (curSample > maxSample) {
        maxSample = curSample
      }
    }
    
    amplitude = 20 * (log(maxSample / 32767.0) / log(10))
  }
  
  func dispose() {
    stop { path in }
  }
  
  // Little endian
  private func convertInt16toUInt8(_ samples: [Int16]) -> [UInt8] {
    var bytes: [UInt8] = []
    
    for sample in samples {
      bytes.append(UInt8(sample & 0x00ff))
      bytes.append(UInt8(sample >> 8 & 0x00ff))
    }
    
    return bytes
  }
  
  private func stream(
    buffer: AVAudioPCMBuffer,
    dstFormat: AVAudioFormat,
    converter: AVAudioConverter,
    recordEventHandler: RecordStreamHandler
  ) -> Void {
    let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    
    // Determine frame capacity
    let capacity = (UInt32(dstFormat.sampleRate) * dstFormat.channelCount * buffer.frameLength) / (UInt32(buffer.format.sampleRate) * buffer.format.channelCount)
    
    // Destination buffer
    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
      print("Unable to create output buffer")
      stop { path in }
      return
    }
    
    // Convert input buffer (resample, num channels)
    var error: NSError? = nil
    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
    if error != nil {
      return
    }
    
    if let channelData = convertedBuffer.int16ChannelData {
      // Fill samples
      let channelDataPointer = channelData.pointee
      let samples = stride(from: 0,
                           to: Int(convertedBuffer.frameLength),
                           by: buffer.stride).map{ channelDataPointer[$0] }

      // Update current amplitude
      updateAmplitude(samples)

      // Send bytes
      if let eventSink = recordEventHandler.eventSink {
        let bytes = Data(_: convertInt16toUInt8(samples))
        
        DispatchQueue.main.async {
          eventSink(FlutterStandardTypedData(bytes: bytes))
        }
      }
    }
  }
  
  // Set up AGC & echo cancel
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
