package com.bechat.bechat

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BLE_STATUS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> {
                    try {
                        result.success(readBleStatus())
                    } catch (error: Throwable) {
                        result.error(
                            "BLE_STATUS_FAILED",
                            error.message ?: "Unable to read Android BLE status.",
                            null,
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }

        val backgroundChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        )
        backgroundChannel.setMethodCallHandler { call, result ->
            BackgroundBleBridge.handleMethodCall(this, call, result)
        }
        BackgroundBleBridge.attach(this, backgroundChannel)
        BackgroundBleBridge.handleLaunchIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        BackgroundBleBridge.handleLaunchIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        BackgroundBleBridge.onRequestPermissionsResult(requestCode, granted)
    }

    override fun onDestroy() {
        if (isFinishing) {
            BeChatForegroundService.stop(applicationContext)
        }
        BackgroundBleBridge.detach(this)
        super.onDestroy()
    }

    @Suppress("MissingPermission")
    private fun readBleStatus(): Map<String, Any> {
        val sdkInt = Build.VERSION.SDK_INT
        val needsNearbyPermissions = sdkInt >= Build.VERSION_CODES.S

        val scan = needsNearbyPermissions &&
            isGranted(Manifest.permission.BLUETOOTH_SCAN)
        val connect = needsNearbyPermissions &&
            isGranted(Manifest.permission.BLUETOOTH_CONNECT)
        val advertise = needsNearbyPermissions &&
            isGranted(Manifest.permission.BLUETOOTH_ADVERTISE)
        val location = !needsNearbyPermissions &&
            isGranted(Manifest.permission.ACCESS_FINE_LOCATION) &&
            isGranted(Manifest.permission.ACCESS_COARSE_LOCATION)

        val permissionsGranted = if (needsNearbyPermissions) {
            scan && connect && advertise
        } else {
            location
        }

        val adapter = try {
            getSystemService(BluetoothManager::class.java)?.adapter
        } catch (_: Throwable) {
            null
        }
        val leSupported = adapter != null &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val bluetoothEnabled = try {
            adapter?.isEnabled == true
        } catch (_: SecurityException) {
            false
        }
        val advertisingSupported = if (bluetoothEnabled) {
            try {
                adapter?.bluetoothLeAdvertiser != null
            } catch (_: SecurityException) {
                false
            }
        } else {
            false
        }

        return mapOf(
            "sdkInt" to sdkInt,
            "scan" to scan,
            "connect" to connect,
            "advertise" to advertise,
            "location" to location,
            "permissionsGranted" to permissionsGranted,
            "bluetoothEnabled" to bluetoothEnabled,
            "leSupported" to leSupported,
            "advertisingSupported" to advertisingSupported,
        )
    }

    private fun isGranted(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            permission,
        ) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        private const val BLE_STATUS_CHANNEL = "bechat/ble_status"
        private const val BACKGROUND_CHANNEL = "bechat/background"
        const val ACTION_OPEN_CHAT = "com.bechat.bechat.OPEN_CHAT"
        const val EXTRA_CHAT_ID = "chatId"
    }
}
