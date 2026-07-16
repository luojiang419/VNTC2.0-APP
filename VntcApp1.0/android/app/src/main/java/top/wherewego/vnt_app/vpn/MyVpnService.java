package top.wherewego.vnt_app.vpn;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.system.OsConstants;
import android.util.Log;

import androidx.core.app.NotificationCompat;

import java.io.IOException;

import top.wherewego.vnt_app.FlutterMethodChannel;
import top.wherewego.vnt_app.MainActivity;
import top.wherewego.vnt_app.MyTileService;
import top.wherewego.vnt_app.R;
import top.wherewego.vnt_app.VntNotificationService;
import top.wherewego.vnt_app.VntWidget;

public class MyVpnService extends VpnService {
    private static final String TAG = "MyVpnService";
    private static final Object VPN_INTERFACE_LOCK = new Object();

    private static ParcelFileDescriptor vpnInterface;
    private static volatile MyVpnService vpnService;

    private volatile boolean foregroundStarted;
    private volatile boolean starting;
    private volatile boolean stopping;
    private volatile boolean stopRequested;

    public static volatile DeviceConfig pendingConfig;


    @Override
    public synchronized int onStartCommand(Intent intent, int flags, int startId) {
        if (!foregroundStarted) {
            FlutterMethodChannel.callError("VPN 前台服务启动失败", null);
            stopSelf();
            return START_NOT_STICKY;
        }

        final DeviceConfig config = pendingConfig;
        pendingConfig = null;
        if (config == null) {
            Log.e(TAG, "启动 VPN 失败：缺少配置");
            FlutterMethodChannel.callError("启动 VPN 失败：缺少 VPN 配置", null);
            if (!hasActiveInterface()) {
                stopRequested = true;
                stopSelf();
            }
            return START_NOT_STICKY;
        }
        if (stopping || stopRequested) {
            FlutterMethodChannel.callError("VPN 正在停止，请稍后重试", null);
            return START_NOT_STICKY;
        }
        if (starting) {
            FlutterMethodChannel.callError("VPN 正在启动，请勿重复连接", null);
            return START_NOT_STICKY;
        }

        starting = true;
        new Thread(() -> {
            try {
                int fd = startVpn(config);
                if (stopRequested || stopping) {
                    throw new IOException("VPN 启动已取消");
                }
                FlutterMethodChannel.callSuccess(fd);
            } catch (SecurityException e) {
                Log.e(TAG, "VPN conflict - another VPN is active", e);
                FlutterMethodChannel.callError("检测到其他 VPN 正在运行，请先断开其他 VPN 后重试", e);
                stopRequested = true;
                stopSelf();
            } catch (Exception e) {
                Log.e(TAG, "Failed to start VPN: " + config, e);
                FlutterMethodChannel.callError("启动 VPN 失败: " + e.getMessage(), e);
                stopRequested = true;
                stopSelf();
            } finally {
                starting = false;
            }
        }, "vnt-vpn-start").start();
        return START_NOT_STICKY;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        vpnService = this;
        try {
            createNotificationChannel();
            startForeground(
                    VntNotificationService.NOTIFICATION_ID,
                    buildForegroundNotification()
            );
            foregroundStarted = true;
            Log.i(TAG, "VPN 前台服务已启动");
        } catch (Exception e) {
            foregroundStarted = false;
            stopRequested = true;
            Log.e(TAG, "VPN 前台服务启动失败", e);
            FlutterMethodChannel.callError("VPN 前台服务启动失败: " + e.getMessage(), e);
            stopSelf();
        }
    }

    public static void stopVpn() {
        MyVpnService service = vpnService;
        if (service != null) {
            service.stopRequested = true;
            service.stopVpnInternal();
        } else {
            closeVpnInterface();
        }
    }

    public static boolean protectSocketFd(int fd) {
        return vpnService != null && fd > 0 && vpnService.protect(fd);
    }

    private int startVpn(DeviceConfig config)
            throws PackageManager.NameNotFoundException, IOException {
        closeVpnInterface();

        Builder builder = new Builder();
        String ip = IpUtils.intToIpAddress(config.virtualIp);
        int prefixLength = IpUtils.subnetMaskToPrefixLength(config.virtualNetmask);
        String ipRoute = IpUtils.intToIpAddress(config.virtualGateway & config.virtualNetmask);
        builder
                .allowFamily(OsConstants.AF_INET)
                .allowFamily(OsConstants.AF_INET6)
                .setBlocking(false)
                .setMtu(config.mtu)
                .addAddress(ip, prefixLength)
                .addRoute(ipRoute, prefixLength);
        if (config.externalRoute != null) {
            for (DeviceConfig.Route routeItem : config.externalRoute) {
                int routePrefixLength = IpUtils.subnetMaskToPrefixLength(routeItem.netmask);
                String routeDest = IpUtils.intToIpAddress(routeItem.destination);
                builder.addRoute(routeDest, routePrefixLength);
            }
        }
        try {
            ParcelFileDescriptor establishedInterface = builder
                    .setSession(getString(R.string.app_name))
                    .establish();
            if (establishedInterface == null) {
                // establish() 返回 null 说明有其他 VPN 正在运行
                Log.e(TAG, "VPN establish failed - another VPN may be active");
                throw new SecurityException("无法建立 VPN 连接。请先断开其他 VPN 应用，然后重试。");
            }
            synchronized (VPN_INTERFACE_LOCK) {
                if (stopRequested || stopping) {
                    establishedInterface.close();
                    throw new IOException("VPN 启动已取消");
                }
                vpnInterface = establishedInterface;
                return establishedInterface.getFd();
            }
        } catch (SecurityException e) {
            Log.e(TAG, "Security exception - another VPN is active", e);
            throw e;
        } catch (Exception e) {
            Log.e(TAG, "Error establishing VPN interface", e);
            throw e;
        }
    }

    @Override
    public void onDestroy() {
        boolean shouldNotifyFlutter = !stopRequested;
        foregroundStarted = false;
        closeVpnInterface();
        if (vpnService == this) {
            vpnService = null;
        }
        stopForeground(true);
        super.onDestroy();
        if (shouldNotifyFlutter && FlutterMethodChannel.initialized()) {
            FlutterMethodChannel.stopVnt();
        }
        Log.i(TAG, "VPN 服务已销毁，资源已释放");
    }

    @Override
    public void onRevoke() {
        Log.w(TAG, "VPN 授权被系统撤销");
        if (FlutterMethodChannel.initialized()) {
            FlutterMethodChannel.stopVnt();
        }
        stopRequested = true;
        stopVpnInternal();
        super.onRevoke();
    }

    private synchronized void stopVpnInternal() {
        if (stopping) {
            return;
        }
        stopping = true;
        closeVpnInterface();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            MyTileService.setState(false);
        }
        VntWidget.updateAllWidgets(this);
        VntNotificationService.updateNotification(this);
        stopForeground(true);
        foregroundStarted = false;
        stopSelf();
    }

    private static boolean hasActiveInterface() {
        synchronized (VPN_INTERFACE_LOCK) {
            return vpnInterface != null;
        }
    }

    private static void closeVpnInterface() {
        synchronized (VPN_INTERFACE_LOCK) {
            if (vpnInterface == null) {
                return;
            }
            try {
                vpnInterface.close();
            } catch (IOException e) {
                Log.e(TAG, "Error closing VPN interface", e);
            } finally {
                vpnInterface = null;
            }
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationChannel channel = new NotificationChannel(
                VntNotificationService.CHANNEL_ID,
                getString(R.string.notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription(getString(R.string.notification_channel_description));
        channel.setShowBadge(false);
        manager.createNotificationChannel(channel);
    }

    private Notification buildForegroundNotification() {
        Intent openAppIntent = new Intent(this, MainActivity.class);
        openAppIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        int pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingIntentFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent contentIntent = PendingIntent.getActivity(
                this,
                0,
                openAppIntent,
                pendingIntentFlags
        );

        return new NotificationCompat.Builder(this, VntNotificationService.CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_icon)
                .setContentTitle(getString(R.string.app_name))
                .setContentText("VNT 虚拟网络正在运行")
                .setContentIntent(contentIntent)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build();
    }
}
