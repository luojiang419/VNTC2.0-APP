package top.wherewego.vnt_app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

public class RemoteAssistControlledService extends Service {
    private static final String CHANNEL_ID = "vnt_remote_assist_controlled";
    private static final int NOTIFICATION_ID = 41091;
    private static volatile boolean running = false;

    public static boolean isRunning() {
        return running;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        running = true;
        startForeground(NOTIFICATION_ID, buildNotification());
        MainActivity.notifyRustdeskStateChange("media", true);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        MainActivity.notifyRustdeskMethod("stop_service", null);
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification buildNotification() {
        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_icon)
                .setContentTitle(getString(R.string.remote_assist_running_title))
                .setContentText(getString(R.string.remote_assist_running_description))
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                getString(R.string.remote_assist_channel_name),
                NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription(getString(R.string.remote_assist_channel_description));
        manager.createNotificationChannel(channel);
    }
}
