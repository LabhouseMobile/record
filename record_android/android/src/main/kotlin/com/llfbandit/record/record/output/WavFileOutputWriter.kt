package com.llfbandit.record.record.output

import android.media.MediaCodec
import android.media.MediaFormat
import com.llfbandit.record.record.RecordConfig
import com.llfbandit.record.record.container.IContainerWriter
import com.llfbandit.record.record.container.WaveContainer
import com.llfbandit.record.record.format.Format
import java.nio.ByteBuffer

/**
 * Output writer that writes PCM audio directly to a WAV file.
 */
class WavFileOutputWriter(
  private val config: RecordConfig,
  private val outputPath: String
) : AudioOutputWriter {
  private var container: IContainerWriter? = null
  private val bufferInfo = MediaCodec.BufferInfo()
  private var errorMessage: String? = null

  override fun start() {
    try {
      val bitsPerSample = 16
      val frameSize = config.numChannels * bitsPerSample / 8
      
      val pcmFormat = MediaFormat().apply {
        setInteger(MediaFormat.KEY_SAMPLE_RATE, config.sampleRate)
        setInteger(MediaFormat.KEY_CHANNEL_COUNT, config.numChannels)
        setInteger(Format.KEY_X_FRAME_SIZE_IN_BYTES, frameSize)
      }
      
      container = WaveContainer(outputPath, frameSize)
      container!!.addTrack(pcmFormat)
      container!!.start()
    } catch (ex: Exception) {
      errorMessage = ex.message
      container = null
    }
  }

  override fun write(buffer: ByteArray) {
    if (errorMessage != null || container == null) return
    
    try {
      val byteBuffer = ByteBuffer.wrap(buffer)
      bufferInfo.offset = 0
      bufferInfo.size = buffer.size
      container!!.writeSampleData(0, byteBuffer, bufferInfo)
    } catch (ex: Exception) {
      errorMessage = ex.message
    }
  }

  override fun stop() {
    try {
      container?.stop()
    } catch (ex: Exception) {
      if (errorMessage == null) {
        errorMessage = ex.message
      }
    }
  }

  override fun release() {
    container?.release()
    container = null
  }

  override fun getOutputPath(): String? {
    return if (errorMessage == null) outputPath else null
  }

  override fun getError(): String? {
    return errorMessage
  }
}

