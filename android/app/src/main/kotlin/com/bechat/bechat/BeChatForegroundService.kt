package com.bechat.bechat

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class BeChatForegroundService : Service() {
    private var stopping = false

    override fun onCreate() {
        super.onCreate()
        instance = this
        try {
            startAsForeground(getString(R.string.background_starting))
        } catch (error: Throwable) {
            instance = null
            BackgroundBleBridge.dispatchServiceFailed(
                "Android could not start the background service.",
            )
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopping = true
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val statusText = intent?.getStringExtra(EXTRA_STATUS_TEXT)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        if (statusText != null) {
            updateNotification(statusText)
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopping = true
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        instance = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (!stopping) {
            BackgroundBleBridge.dispatchServiceFailed(
                "Android stopped background mode. Open BeChat to restart it.",
            )
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startAsForeground(statusText: String) {
        val notification = BackgroundNotifications.buildServiceNotification(
            this,
            statusText,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                BackgroundNotifications.serviceNotificationId(),
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(
                BackgroundNotifications.serviceNotificationId(),
                notification,
            )
        }
    }

    private fun updateNotification(statusText: String) {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(
                BackgroundNotifications.serviceNotificationId(),
                BackgroundNotifications.buildServiceNotification(this, statusText),
            )
        } catch (error: Throwable) {
            BackgroundBleBridge.dispatchServiceFailed(
                "Could not update the background notification.",
            )
        }
    }

    companion object {
        const val ACTION_START = "com.bechat.bechat.START_BACKGROUND"
        const val ACTION_STOP = "com.bechat.bechat.STOP_BACKGROUND"
        const val EXTRA_STATUS_TEXT = "statusText"

        @Volatile
        private var instance: BeChatForegroundService? = null

        val isRunning: Boolean
            get() = instance != null

        fun updateStatus(statusText: String): Boolean {
            val service = instance ?: return false
            service.updateNotification(statusText)
            return true
        }

        fun start(context: Context, statusText: String) {
            val intent = Intent(context, BeChatForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_STATUS_TEXT, statusText)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            instance?.stopping = true
            context.stopService(Intent(context, BeChatForegroundService::class.java))
        }
    }
}
