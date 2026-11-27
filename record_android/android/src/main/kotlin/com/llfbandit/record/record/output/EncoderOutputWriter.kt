package com.llfbandit.record.record.output

import com.llfbandit.record.record.RecordConfig
import com.llfbandit.record.record.encoder.EncoderListener
import com.llfbandit.record.record.encoder.IEncoder
import com.llfbandit.record.record.format.Format

/**
 * Output writer that encodes PCM audio to a compressed format (AAC, Opus, etc.)
 * using the provided encoder.
 */
class EncoderOutputWriter(
  private val config: RecordConfig,
  private val format: Format,
  private val listener: EncoderListener
) : AudioOutputWriter {
  private var encoder: IEncoder? = null

  // Volatile: codec and muxer failures arrive on the encoder's handler thread
  @Volatile
  private var errorMessage: String? = null

  private val trackingListener = object : EncoderListener {
    override fun onEncoderFailure(ex: Exception) {
      if (errorMessage == null) errorMessage = ex.message ?: ex.toString()
      listener.onEncoderFailure(ex)
    }

    override fun onEncoderStream(bytes: ByteArray) = listener.onEncoderStream(bytes)
  }

  override val configuredPath: String?
    get() = config.path

  override fun start() {
    try {
      val (newEncoder, _) = format.getEncoder(config, trackingListener)
      encoder = newEncoder
      newEncoder.startEncoding()
    } catch (ex: Exception) {
      errorMessage = ex.message ?: ex.toString()
      encoder = null
      throw ex
    }
  }

  override fun write(buffer: ByteArray) {
    if (errorMessage != null) return
    
    try {
      encoder?.encode(buffer)
    } catch (ex: Exception) {
      errorMessage = ex.message ?: ex.toString()
    }
  }

  override fun stop() {
    try {
      encoder?.stopEncoding()
    } catch (ex: Exception) {
      if (errorMessage == null) {
        errorMessage = ex.message ?: ex.toString()
      }
    }
  }

  override fun release() {
    encoder = null
  }

  override fun getOutputPath(): String? {
    return if (errorMessage == null) config.path else null
  }

  override fun getError(): String? {
    return errorMessage
  }
}

