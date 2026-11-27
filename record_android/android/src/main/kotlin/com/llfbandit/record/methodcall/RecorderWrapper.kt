package com.llfbandit.record.methodcall

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.AudioDeviceInfo
import android.os.IBinder
import com.llfbandit.record.record.RecordConfig
import com.llfbandit.record.record.bluetooth.BluetoothReceiver
import com.llfbandit.record.record.bluetooth.BluetoothScoListener
import com.llfbandit.record.record.encoder.EncoderListener
import com.llfbandit.record.record.output.AudioOutputWriter
import com.llfbandit.record.record.output.EncoderOutputWriter
import com.llfbandit.record.record.output.WavFileOutputWriter
import com.llfbandit.record.record.recorder.AudioRecorder
import com.llfbandit.record.record.recorder.IRecorder
import com.llfbandit.record.record.recorder.MediaRecorder
import com.llfbandit.record.record.stream.RecorderRecordStreamHandler
import com.llfbandit.record.record.stream.RecorderStateStreamHandler
import com.llfbandit.record.service.AudioRecordingService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel


class RecorderWrapper(
  private val context: Context,
  recorderId: String,
  messenger: BinaryMessenger,
) : BluetoothScoListener {
  companion object {
    const val EVENTS_STATE_CHANNEL = "com.llfbandit.record/events/"
    const val EVENTS_RECORD_CHANNEL = "com.llfbandit.record/eventsRecord/"
  }

  private var eventChannel: EventChannel?
  private val recorderStateStreamHandler = RecorderStateStreamHandler()
  private var eventRecordChannel: EventChannel?
  private val recorderRecordStreamHandler = RecorderRecordStreamHandler()
  private var recorder: IRecorder? = null
  private var bluetoothReceiver: BluetoothReceiver? = null
  private var m4aWriter: EncoderOutputWriter? = null
  private var wavWriter: WavFileOutputWriter? = null

  init {
    eventChannel = EventChannel(messenger, EVENTS_STATE_CHANNEL + recorderId)
    eventChannel?.setStreamHandler(recorderStateStreamHandler)
    eventRecordChannel = EventChannel(messenger, EVENTS_RECORD_CHANNEL + recorderId)
    eventRecordChannel?.setStreamHandler(recorderRecordStreamHandler)
  }

  fun startRecordingToFile(config: RecordConfig, result: MethodChannel.Result) {
    clearDualWriters()
    startRecording(config, emptyList(), result)
  }

  fun startRecordingToStream(config: RecordConfig, result: MethodChannel.Result) {
    if (config.useLegacy) {
      throw Exception("Cannot stream audio while using the legacy recorder")
    }
    clearDualWriters()
    startRecording(config, emptyList(), result)
  }

  fun startRecordingToDual(config: RecordConfig, basePath: String, result: MethodChannel.Result) {
    if (config.useLegacy) {
      throw Exception("Cannot stream audio while using the legacy recorder")
    }

    // Add encoder output (M4A) - Force AAC encoding for M4A output
    // Create a modified config with AAC encoder for the M4A file
    val m4aConfig = RecordConfig(
      path = config.path, // M4A path
      encoder = "aacLc", // Force AAC encoding as string
      bitRate = config.bitRateOutput ?: config.bitRate,
      bitRateOutput = config.bitRateOutput,
      sampleRate = config.sampleRate,
      numChannels = config.numChannels,
      device = config.device,
      autoGain = config.autoGain,
      echoCancel = config.echoCancel,
      noiseSuppress = config.noiseSuppress,
      useLegacy = false,
      service = config.service,
      muteAudio = config.muteAudio,
      manageBluetooth = config.manageBluetooth,
      audioSource = config.audioSource,
      speakerphone = config.speakerphone,
      audioManagerMode = config.audioManagerMode,
      audioInterruption = config.audioInterruption.ordinal, // Convert enum to Int
      streamBufferSize = config.streamBufferSize
    )
    
    val format = com.llfbandit.record.record.format.AacFormat()
    val encoderListener = object : EncoderListener {
      override fun onEncoderFailure(ex: Exception) {
        // EncoderOutputWriter records the failure and stopDual reports it
      }
      override fun onEncoderStream(bytes: ByteArray) {
        // Stream is handled separately by RecordThread
      }
    }
    val m4a = EncoderOutputWriter(m4aConfig, format, encoderListener)
    
    // Add WAV output
    val wav = WavFileOutputWriter(config, "$basePath.wav")
    
    m4aWriter = m4a
    wavWriter = wav
    startRecording(config, listOf(m4a, wav), result)
  }

  // A single-output recording has no dual results to report
  private fun clearDualWriters() {
    m4aWriter = null
    wavWriter = null
  }


  fun dispose() {
    try {
      recorder?.dispose()
    } catch (_: Exception) {
    } finally {
      maybeStopBluetooth()
      stopService()
      recorder = null
    }

    eventChannel?.setStreamHandler(null)
    eventChannel = null

    eventRecordChannel?.setStreamHandler(null)
    eventRecordChannel = null
  }

  fun pause(result: MethodChannel.Result) {
    try {
      recorder?.pause()
      result.success(null)
    } catch (e: Exception) {
      result.error("record", e.message, e.cause)
    }
  }

  fun isPaused(result: MethodChannel.Result) {
    result.success(recorder?.isPaused ?: false)
  }

  fun isRecording(result: MethodChannel.Result) {
    result.success(recorder?.isRecording ?: false)
  }

  fun getAmplitude(result: MethodChannel.Result) {
    if (recorder != null) {
      val amps = recorder!!.getAmplitude()
      val amp: MutableMap<String, Any> = HashMap()
      amp["current"] = amps[0]
      amp["max"] = amps[1]
      result.success(amp)
    } else {
      result.success(null)
    }
  }

  fun resume(result: MethodChannel.Result) {
    try {
      recorder?.resume()
      result.success(null)
    } catch (e: Exception) {
      result.error("record", e.message, e.cause)
    }
  }

  fun stop(result: MethodChannel.Result) {
    try {
      if (recorder == null) {
        result.success(null)
      } else {
        recorder?.stop(fun(path) = result.success(path))
      }
    } catch (e: Exception) {
      result.error("record", e.message, e.cause)
    } finally {
      stopService()
    }
  }

  fun stopDual(result: MethodChannel.Result) {
    try {
      if (recorder == null) {
        result.success(null)
        return
      }
      
      // Stop recording; a path is only returned when its writer succeeded
      recorder?.stop { _ ->
        val response = mapOf(
          "m4aPath" to m4aWriter?.getOutputPath(),
          "wavPath" to wavWriter?.getOutputPath(),
          "m4aError" to m4aWriter?.getError(),
          "wavError" to wavWriter?.getError()
        )
        
        result.success(response)
      }
    } catch (e: Exception) {
      result.error("record", e.message, e.cause)
    } finally {
      stopService()
    }
  }

  fun cancel(result: MethodChannel.Result) {
    try {
      recorder?.cancel()
      result.success(null)
    } catch (e: Exception) {
      result.error("record", e.message, e.cause)
    }

    maybeStopBluetooth()
  }

  private fun startRecording(
    config: RecordConfig,
    outputWriters: List<AudioOutputWriter>,
    result: MethodChannel.Result
  ) {
    try {
      if (recorder == null) {
        recorder = createRecorder(config)
        start(config, outputWriters, result)
      } else if (recorder!!.isRecording) {
        recorder!!.stop(fun(_) = start(config, outputWriters, result))
      } else {
        start(config, outputWriters, result)
      }

      startService(config)
    } catch (e: Exception) {
      result.error("record", e.message, e.cause)
    }
  }

  private fun createRecorder(config: RecordConfig): IRecorder {
    if (config.manageBluetooth) {
      maybeStartBluetooth(config)
    }

    if (config.useLegacy) {
      return MediaRecorder(context, recorderStateStreamHandler)
    }

    return AudioRecorder(
      recorderStateStreamHandler,
      recorderRecordStreamHandler,
      context
    )
  }

  private fun start(
    config: RecordConfig,
    outputWriters: List<AudioOutputWriter>,
    result: MethodChannel.Result
  ) {
    if (recorder is AudioRecorder && outputWriters.isNotEmpty()) {
      (recorder as AudioRecorder).startWithOutputs(config, outputWriters)
    } else {
      recorder!!.start(config)
    }
    result.success(null)
  }

  ///////////////////////////////////////////////////////////
  // Service
  ///////////////////////////////////////////////////////////
//    private var mService: AudioRecordingService? = null
  private var mServiceBound = false

  private val serviceConnection = object : ServiceConnection {
    override fun onServiceConnected(className: ComponentName, service: IBinder) {
//            val binder = service as AudioRecordingService.LocalBinder
//            mService = binder.getService()
    }

    override fun onServiceDisconnected(className: ComponentName) {
//            mService = null
    }
  }

  private fun startService(config: RecordConfig) {
    if (config.service != null) {
      val intent = Intent(context, AudioRecordingService::class.java)
      intent.putExtra("title", config.service.title)
      intent.putExtra("content", config.service.content)
      context.startService(intent)

      Intent(context, AudioRecordingService::class.java).also { intent ->
        mServiceBound = context.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
      }
    }
  }

  private fun stopService() {
    if (mServiceBound) {
      context.unbindService(serviceConnection)
      context.stopService(Intent(context, AudioRecordingService::class.java))
      mServiceBound = false
    }
  }

  ///////////////////////////////////////////////////////////
  // Bluetooth SCO
  ///////////////////////////////////////////////////////////
  private fun maybeStartBluetooth(config: RecordConfig) {
    if (config.device != null && config.device.type != AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
      maybeStopBluetooth()
      return
    }

    if (bluetoothReceiver == null) {
      bluetoothReceiver = BluetoothReceiver(context)
    }

    if (!bluetoothReceiver!!.hasListeners()) {
      bluetoothReceiver!!.register()
      bluetoothReceiver!!.addListener(this)
    }
  }

  private fun maybeStopBluetooth() {
    bluetoothReceiver?.removeListener(this)

    if (bluetoothReceiver?.hasListeners() != true) {
      bluetoothReceiver?.unregister()
    }
  }

  override fun onBlScoConnected() {
  }

  override fun onBlScoDisconnected() {
  }
}
