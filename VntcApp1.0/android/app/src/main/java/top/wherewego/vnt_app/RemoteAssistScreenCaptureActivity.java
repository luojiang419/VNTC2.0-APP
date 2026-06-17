package top.wherewego.vnt_app;

import android.app.Activity;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;

import androidx.annotation.Nullable;

public class RemoteAssistScreenCaptureActivity extends Activity {
    public static final String EXTRA_START_SERVICE = "start_service";
    private static final int REQUEST_MEDIA_PROJECTION = 7001;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        MediaProjectionManager manager =
                (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        if (manager == null) {
            finish();
            return;
        }
        startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_MEDIA_PROJECTION) {
            finish();
            return;
        }

        if (resultCode == RESULT_OK && data != null) {
            RemoteAssistStateHolder.setMediaProjectionPermission(resultCode, data);
            MainActivity.notifyRustdeskStateChange("media", true);
            if (getIntent().getBooleanExtra(EXTRA_START_SERVICE, false)) {
                Intent serviceIntent = new Intent(this, RemoteAssistControlledService.class);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent);
                } else {
                    startService(serviceIntent);
                }
            }
            setResult(RESULT_OK);
        } else {
            MainActivity.notifyRustdeskMethod("on_media_projection_canceled", null);
            setResult(RESULT_CANCELED);
        }
        finish();
    }
}
