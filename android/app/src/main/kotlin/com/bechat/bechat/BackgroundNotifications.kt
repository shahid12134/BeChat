package com.bechat.bechat

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs

object BackgroundNotifications {
    const val CHANNEL_SERVICE = "bechat_background"
    const val CHANNEL_MESSAGES = "bechat_messages"
    const val CHANNEL_REQUESTS = "bechat_connection_requests"

    const val ACTION_BACKGROUND_REQUEST = "com.bechat.bechat.BACKGROUND_REQUEST"
    const val EXTRA_REQUEST_ID = "requestId"
    const val EXTRA_REQUEST_ACTION = "requestAction"

    const val REQUEST_ACCEPT = "accept"
    const val REQUEST_DECLINE = "decline"
    const val REQUEST_BLOCK = "block"

    private const val SERVICE_NOTIFICATION_ID = 1001
    private const val MESSAGE_ID_BASE = 0x20000000
    private const val REQUEST_ID_BASE = 0x40000000
    private const val PENDING_FLAGS =
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SERVICE,
                "Background mode",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while BeChat can receive nearby messages."
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MESSAGES,
                "Messages",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "New messages received over nearby connections."
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_REQUESTS,
                "Connection requests",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Nearby peers asking to connect to BeChat."
            },
        )
    }

    fun notificationsAllowed(context: Context): Boolean {
        val enabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        if (!enabled) return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
    }

    fun buildServiceNotification(context: Context, statusText: String): Notification {
        ensureChannels(context)
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            SERVICE_NOTIFICATION_ID,
            launch,
            PENDING_FLAGS,
        )
        return NotificationCompat.Builder(context, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_bechat)
            .setContentTitle("BeChat background mode")
            .setContentText(statusText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(statusText))
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .build()
    }

    fun serviceNotificationId(): Int = SERVICE_NOTIFICATION_ID

    fun showMessage(
        context: Context,
        messageId: String,
        chatId: String,
        senderName: String,
        body: String,
    ) {
        ensureChannels(context)
        if (!notificationsAllowed(context)) return
        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_CHAT
            putExtra(MainActivity.EXTRA_CHAT_ID, chatId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val notificationId = MESSAGE_ID_BASE + (messageId.hashCode() and 0x0FFFFFFF)
        val contentIntent = PendingIntent.getActivity(
            context,
            notificationId,
            intent,
            PENDING_FLAGS,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_bechat)
            .setContentTitle(senderName)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
        } catch (_: SecurityException) {
        }
    }

    fun showConnectionRequest(context: Context, requestId: String, peerName: String) {
        ensureChannels(context)
        if (!notificationsAllowed(context)) return
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val notificationId = requestNotificationId(requestId)
        val contentIntent = PendingIntent.getActivity(
            context,
            notificationId,
            openIntent,
            PENDING_FLAGS,
        )
        val text = "$peerName wants to connect nearby."
        val notification = NotificationCompat.Builder(context, CHANNEL_REQUESTS)
            .setSmallIcon(R.drawable.ic_stat_bechat)
            .setContentTitle("Connection request")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(
                R.drawable.ic_stat_bechat,
                "Accept",
                requestActionIntent(
                    context,
                    requestId,
                    REQUEST_ACCEPT,
                    notificationId,
                ),
            )
            .addAction(
                R.drawable.ic_stat_bechat,
                "Decline",
                requestActionIntent(
                    context,
                    requestId,
                    REQUEST_DECLINE,
                    notificationId,
                ),
            )
            .addAction(
                R.drawable.ic_stat_bechat,
                "Block",
                requestActionIntent(
                    context,
                    requestId,
                    REQUEST_BLOCK,
                    notificationId,
                ),
            )
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
        } catch (_: SecurityException) {
        }
    }

    fun cancelConnectionRequest(context: Context, requestId: String) {
        NotificationManagerCompat.from(context)
            .cancel(requestNotificationId(requestId))
    }

    fun openNotificationSettings(context: Context) {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (_: Throwable) {
            try {
                val fallback = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(fallback)
            } catch (_: Throwable) {
            }
        }
    }

    private fun requestActionIntent(
        context: Context,
        requestId: String,
        action: String,
        notificationId: Int,
    ): PendingIntent {
        val intent = Intent(context, BackgroundActionReceiver::class.java).apply {
            this.action = ACTION_BACKGROUND_REQUEST
            data = Uri.parse("bechat://request/$requestId/$action")
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_REQUEST_ACTION, action)
        }
        val requestCode = notificationId + action.hashCode()
        return PendingIntent.getBroadcast(context, requestCode, intent, PENDING_FLAGS)
    }

    private fun requestNotificationId(requestId: String): Int =
        REQUEST_ID_BASE + (abs(requestId.hashCode()) and 0x0FFFFFFF)
}
