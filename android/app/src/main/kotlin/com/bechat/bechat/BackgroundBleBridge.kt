package com.bechat.bechat

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

object BackgroundBleBridge {
    private const val CHANNEL_NAME = "bechat/background"
    private const val PERMISSION_REQUEST_CODE = 4301
    private const val MAX_PENDING_EVENTS = 20

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingEvents = ArrayDeque<Map<String, Any?>>()
    private var channel: MethodChannel? = null
    private var activityRef: WeakReference<Activity>? = null
    private var dartReady = false
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun attach(activity: Activity, methodChannel: MethodChannel) {
        activityRef = WeakReference(activity)
        channel = methodChannel
        dartReady = false
    }

    fun detach(activity: Activity) {
        if (activityRef?.get() !== activity) return
        activityRef = null
        channel = null
        dartReady = false
        pendingPermissionResult?.success(false)
        pendingPermissionResult = null
    }

    fun handleMethodCall(
        activity: Activity,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        activityRef = WeakReference(activity)
        when (call.method) {
            "initialize" -> {
                dartReady = true
                val events = pendingEvents.toList()
                pendingEvents.clear()
                result.success(events)
            }

            "getStatus" -> result.success(readStatus(activity))

            "requestNotificationPermission" -> {
                requestNotificationPermission(activity, result)
            }

            "openNotificationSettings" -> {
                BackgroundNotifications.openNotificationSettings(activity)
                result.success(null)
            }

            "startService" -> {
                val statusText = call.argument<String>("statusText")
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                    ?: activity.getString(R.string.background_starting)
                try {
                    BackgroundNotifications.ensureChannels(activity)
                    BeChatForegroundService.start(activity.applicationContext, statusText)
                    result.success(null)
                } catch (error: Throwable) {
                    result.error(
                        "BACKGROUND_START_FAILED",
                        error.message ?: "Android could not start background mode.",
                        null,
                    )
                }
            }

            "updateService" -> {
                val statusText = call.argument<String>("statusText") ?: ""
                if (BeChatForegroundService.updateStatus(statusText)) {
                    result.success(null)
                } else {
                    result.error(
                        "BACKGROUND_NOT_RUNNING",
                        "The background service is not running.",
                        null,
                    )
                }
            }

            "stopService" -> {
                BeChatForegroundService.stop(activity.applicationContext)
                result.success(null)
            }

            "showMessageNotification" -> {
                val messageId = call.argument<String>("messageId")
                val chatId = call.argument<String>("chatId")
                val senderName = call.argument<String>("senderName")
                val body = call.argument<String>("body")
                if (messageId == null || chatId == null ||
                    senderName == null || body == null
                ) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "Message notification details are missing.",
                        null,
                    )
                    return
                }
                BackgroundNotifications.showMessage(
                    activity,
                    messageId,
                    chatId,
                    senderName,
                    body,
                )
                result.success(null)
            }

            "showConnectionRequestNotification" -> {
                val requestId = call.argument<String>("requestId")
                val peerName = call.argument<String>("peerName")
                if (requestId == null || peerName == null) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "Connection request details are missing.",
                        null,
                    )
                    return
                }
                BackgroundNotifications.showConnectionRequest(
                    activity,
                    requestId,
                    peerName,
                )
                result.success(null)
            }

            "cancelConnectionRequestNotification" -> {
                val requestId = call.argument<String>("requestId")
                if (requestId == null) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "Connection request ID is missing.",
                        null,
                    )
                    return
                }
                BackgroundNotifications.cancelConnectionRequest(activity, requestId)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, granted: Boolean) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val context = activityRef?.get() ?: return
        result.success(granted && BackgroundNotifications.notificationsAllowed(context))
    }

    fun dispatchAction(type: String, requestId: String): Boolean {
        if (!dartReady) return false
        val event = mapOf(
            "type" to type,
            "eventId" to "$requestId:$type",
            "requestId" to requestId,
        )
        return dispatchEvent(event)
    }

    fun dispatchServiceFailed(message: String) {
        val event = mapOf(
            "type" to "serviceFailed",
            "eventId" to "serviceFailed:${System.currentTimeMillis()}",
            "message" to message,
        )
        if (!dispatchEvent(event)) {
            enqueue(event)
        }
    }

    fun handleLaunchIntent(intent: Intent) {
        if (intent.action != MainActivity.ACTION_OPEN_CHAT) return
        val chatId = intent.getStringExtra(MainActivity.EXTRA_CHAT_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return
        intent.removeExtra(MainActivity.EXTRA_CHAT_ID)
        val event = mapOf(
            "type" to "openChat",
            "eventId" to "openChat:$chatId:${System.currentTimeMillis()}",
            "chatId" to chatId,
        )
        if (!dispatchEvent(event)) {
            enqueue(event)
        }
    }

    private fun dispatchEvent(event: Map<String, Any?>): Boolean {
        val methodChannel = channel
        if (!dartReady || methodChannel == null) return false
        mainHandler.post {
            if (dartReady && channel === methodChannel) {
                methodChannel.invokeMethod("backgroundEvent", event)
            }
        }
        return true
    }

    private fun enqueue(event: Map<String, Any?>) {
        pendingEvents.addLast(event)
        while (pendingEvents.size > MAX_PENDING_EVENTS) {
            pendingEvents.removeFirst()
        }
    }

    private fun readStatus(context: Context): Map<String, Any> {
        val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        return mapOf(
            "supported" to supported,
            "notificationsAllowed" to BackgroundNotifications.notificationsAllowed(context),
            "serviceRunning" to BeChatForegroundService.isRunning,
        )
    }

    private fun requestNotificationPermission(
        activity: Activity,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(BackgroundNotifications.notificationsAllowed(activity))
            return
        }
        if (ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(BackgroundNotifications.notificationsAllowed(activity))
            return
        }
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE,
        )
    }
}
