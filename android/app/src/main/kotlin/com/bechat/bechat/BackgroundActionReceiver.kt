package com.bechat.bechat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BackgroundActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BackgroundNotifications.ACTION_BACKGROUND_REQUEST) {
            return
        }
        val requestId = intent.getStringExtra(BackgroundNotifications.EXTRA_REQUEST_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return
        val action = intent.getStringExtra(BackgroundNotifications.EXTRA_REQUEST_ACTION)
            ?: return
        val eventType = when (action) {
            BackgroundNotifications.REQUEST_ACCEPT -> "acceptConnectionRequest"
            BackgroundNotifications.REQUEST_DECLINE -> "declineConnectionRequest"
            BackgroundNotifications.REQUEST_BLOCK -> "blockConnectionRequest"
            else -> return
        }
        BackgroundNotifications.cancelConnectionRequest(context, requestId)
        BackgroundBleBridge.dispatchAction(eventType, requestId)
    }
}
