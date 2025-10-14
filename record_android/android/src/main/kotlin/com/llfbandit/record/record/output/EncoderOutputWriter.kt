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
  private var errorMessage: String? = null

  override fun start() {
    val (newEncoder, _) = format.getEncoder(config, listener)
    encoder = newEncoder
    encoder?.startEncoding()
  }

  override fun write(buffer: ByteArray) {
    if (errorMessage != null) return
    
    try {
      encoder?.encode(buffer)
    } catch (ex: Exception) {
      errorMessage = ex.message
    }
  }

  override fun stop() {
    try {
      encoder?.stopEncoding()
    } catch (ex: Exception) {
      if (errorMessage == null) {
        errorMessage = ex.message
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

