package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.content.ContextCompat
import top.wherewego.vnt_app.MainActivity as VntMainActivity

class PermissionRequestTransparentActivity: Activity() {
    private val logTag = "permissionRequest"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(logTag, "onCreate PermissionRequestTransparentActivity: intent.action: ${intent.action}")

        if (savedInstanceState != null) {
            return
        }

        when (intent.action) {
            ACT_REQUEST_MEDIA_PROJECTION -> {
                val mediaProjectionManager =
                    getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val captureIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    mediaProjectionManager.createScreenCaptureIntent(
                        MediaProjectionConfig.createConfigForDefaultDisplay()
                    )
                } else {
                    mediaProjectionManager.createScreenCaptureIntent()
                }
                MainService.markProjectionRequestStarted()
                VntMainActivity.notifyRustdeskMethod("on_media_projection_request_started", null)
                startActivityForResult(captureIntent, REQ_REQUEST_MEDIA_PROJECTION)
            }
            else -> finish()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_REQUEST_MEDIA_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                launchService(data)
                setResult(RESULT_OK)
            } else {
                setResult(RES_FAILED)
                MainService.markProjectionRequestCancelled()
                VntMainActivity.notifyRustdeskStateChange("media", false)
                VntMainActivity.notifyRustdeskMethod("on_media_projection_canceled", null)
            }
        }

        finish()
    }

    private fun launchService(mediaProjectionResultIntent: Intent) {
        Log.d(logTag, "Launch MainService")
        val serviceIntent = Intent(this, MainService::class.java)
        serviceIntent.action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
        serviceIntent.putExtra(EXT_MEDIA_PROJECTION_RES_INTENT, mediaProjectionResultIntent)

        try {
            ContextCompat.startForegroundService(this, serviceIntent)
        } catch (error: Exception) {
            Log.e(logTag, "Failed to launch MainService", error)
            MainService.markProjectionRequestFailed(
                error.message ?: "无法启动屏幕录制前台服务"
            )
            VntMainActivity.notifyRustdeskStateChange("media", false)
            VntMainActivity.notifyRustdeskMethod(
                "on_media_projection_failed",
                mapOf("reason" to "service_start_failed", "message" to (error.message ?: ""))
            )
        }
    }

}
