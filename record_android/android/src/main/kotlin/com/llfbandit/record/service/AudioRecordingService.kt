package com.llfbandit.record.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.VISIBILITY_PUBLIC
import com.llfbandit.record.R

class AudioRecordingService : Service() {
  companion object {
    private const val CHANNEL_ID = "AudioRecordingChannel"
    private const val NOTIFICATION_ID = 1
    const val DEFAULT_TITLE = "Audio Capture"
  }

  private val binder: IBinder = LocalBinder()
  private lateinit var notificationManager: NotificationManager

  inner class LocalBinder : Binder() {
//        fun getService(): AudioRecordingService = this@AudioRecordingService
  }

  override fun onBind(intent: Intent): IBinder {
    return binder
  }

  override fun onCreate() {
    super.onCreate()
    createNotificationChannel()
  }

  override fun onDestroy() {
    super.onDestroy()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == null) {
      val notification = createNotification(
        intent?.getStringExtra("title"),
        intent?.getStringExtra("content")
      )

      // From Android 11 (API 30) on, a foreground service is denied microphone
      // I/O while the app is backgrounded unless it is started with the
      // microphone foreground service type. Without it, OEM-skinned devices
      // (vivo, Xiaomi, OnePlus, Samsung, ...) silently stop writing audio
      // frames to disk, truncating the recording. On Android 14 (API 34+) this
      // type is mandatory and additionally requires the
      // FOREGROUND_SERVICE_MICROPHONE permission. See bug #1674.
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        startForeground(
          NOTIFICATION_ID,
          notification,
          ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        )
      } else {
        startForeground(NOTIFICATION_ID, notification)
      }

      notificationManager.notify(NOTIFICATION_ID, notification)
    }

    return START_NOT_STICKY
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val channel = NotificationChannel(
        CHANNEL_ID,
        DEFAULT_TITLE,
        NotificationManager.IMPORTANCE_LOW
      )

      notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
      notificationManager.createNotificationChannel(channel)
    }
  }

  private fun createNotification(title: String?, content: String?): Notification {
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(title ?: DEFAULT_TITLE)
      .setContentText(content)
      .setSmallIcon(R.drawable.ic_mic)
      .setSilent(true)
      .setOngoing(true)
      .setVisibility(VISIBILITY_PUBLIC)
      .build()
  }
}