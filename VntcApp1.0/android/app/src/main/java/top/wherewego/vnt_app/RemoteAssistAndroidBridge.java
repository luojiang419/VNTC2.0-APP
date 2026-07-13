package top.wherewego.vnt_app;

import android.Manifest;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.TextUtils;

import androidx.core.content.ContextCompat;

import java.io.File;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.zip.ZipFile;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class RemoteAssistAndroidBridge {
    private static final String CHANNEL = "top.wherewego.vnt/remote_assist_android";
    private static final int DIRECT_ACCESS_PORT = 49999;

    private final MainActivity activity;

    public RemoteAssistAndroidBridge(MainActivity activity, FlutterEngine flutterEngine) {
        this.activity = activity;
        MethodChannel channel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                CHANNEL
        );
        channel.setMethodCallHandler(this::onMethodCall);
    }

    private void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "getStatus":
                    result.success(buildStatus());
                    return;
                case "refreshState":
                    activity.refreshRustdeskServiceState();
                    result.success(null);
                    return;
                case "requestPermission":
                    requestPermission(
                            readString(call.argument("permission")),
                            false
                    );
                    result.success(null);
                    return;
                case "openSystemSettings":
                    openSystemSettings(readString(call.argument("section")));
                    result.success(null);
                    return;
                case "startControlledService":
                    startControlledService();
                    result.success(null);
                    return;
                case "stopControlledService":
                    stopControlledService();
                    result.success(null);
                    return;
                case "connectByVirtualIp":
                    if (hasBundledRustdeskController()) {
                        result.success(null);
                    } else {
                        result.error(
                                "CONTROLLER_UNAVAILABLE",
                                "当前安装包未包含适用于本机架构的内置控制端。",
                                null
                        );
                    }
                    return;
                case "setAccessPassword":
                    RemoteAssistStateHolder.setAccessPassword(
                            readString(call.argument("password"))
                    );
                    result.success(null);
                    return;
                default:
                    result.notImplemented();
            }
        } catch (Exception error) {
            result.error("REMOTE_ASSIST_ANDROID_ERROR", error.getMessage(), null);
        }
    }

    private Map<String, Object> buildStatus() {
        Map<String, Object> status = new HashMap<>();
        boolean notificationGranted = hasNotificationPermission();
        boolean screenCaptureGranted =
                com.carriez.flutter_hbb.MainService.Companion.isReady();
        boolean accessibilityGranted = isAccessibilityConnected();
        boolean accessibilitySettingEnabled = isAccessibilitySettingEnabled();
        boolean overlayGranted = Settings.canDrawOverlays(activity);
        boolean batteryOptimizationIgnored = isIgnoringBatteryOptimizations();
        boolean controllerAvailable = hasBundledRustdeskController();
        boolean controlledServiceRunning =
                com.carriez.flutter_hbb.MainService.Companion.isReady();
        boolean portListening = controlledServiceRunning && isTcpPortListening(DIRECT_ACCESS_PORT);
        status.put("notificationPermissionGranted", hasNotificationPermission());
        status.put("screenCapturePermissionGranted", screenCaptureGranted);
        status.put("accessibilityPermissionGranted", accessibilityGranted);
        status.put("accessibilitySettingEnabled", accessibilitySettingEnabled);
        status.put("overlayPermissionGranted", overlayGranted);
        status.put("batteryOptimizationIgnored", batteryOptimizationIgnored);
        status.put("controllerAvailable", controllerAvailable);
        status.put("controlledRoleSupported", true);
        status.put("controlledRuntimeReady", portListening);
        status.put("controlledServiceRunning", controlledServiceRunning);
        status.put(
                "permissionsReady",
                notificationGranted
                        && screenCaptureGranted
                        && accessibilityGranted
                        && overlayGranted
                        && batteryOptimizationIgnored
        );
        status.put("listenerReady", portListening);
        status.put("runtimeVersion", "android-integrated-v3");
        status.put("runtimeAvailable", true);
        status.put("serviceInstalled", true);
        status.put("serviceRunning", controlledServiceRunning);
        status.put("portListening", portListening);
        return status;
    }

    private boolean isTcpPortListening(int port) {
        String expectedPort = String.format(Locale.US, "%04X", port);
        return isTcpPortListeningIn("/proc/self/net/tcp", expectedPort)
                || isTcpPortListeningIn("/proc/self/net/tcp6", expectedPort);
    }

    private boolean isTcpPortListeningIn(String path, String expectedPort) {
        try (BufferedReader reader = new BufferedReader(new FileReader(path))) {
            String line;
            while ((line = reader.readLine()) != null) {
                String[] columns = line.trim().split("\\s+");
                if (columns.length < 4) {
                    continue;
                }
                String localAddress = columns[1].toUpperCase(Locale.US);
                String state = columns[3];
                if ("0A".equals(state) && localAddress.endsWith(":" + expectedPort)) {
                    return true;
                }
            }
        } catch (IOException ignored) {
            // procfs 不可读时保持未就绪，避免把前台服务误报成端口监听。
        }
        return false;
    }

    private void requestPermission(String permission, boolean startServiceAfterGrant) {
        switch (permission) {
            case "screen_capture":
                Intent intent = new Intent(
                        activity,
                        com.carriez.flutter_hbb.PermissionRequestTransparentActivity.class
                );
                intent.setAction("REQUEST_MEDIA_PROJECTION");
                activity.startActivity(intent);
                break;
            case "accessibility":
                openSystemSettings("accessibility");
                break;
            case "overlay":
                openSystemSettings("overlay");
                break;
            case "battery_optimization":
                openSystemSettings("battery_optimization");
                break;
            case "notification":
                openSystemSettings("notifications");
                break;
            default:
                break;
        }
    }

    private void openSystemSettings(String section) {
        Intent intent;
        switch (section) {
            case "screen_capture":
                requestPermission("screen_capture", false);
                return;
            case "accessibility":
                intent = new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS);
                break;
            case "overlay":
                intent = new Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + activity.getPackageName())
                );
                break;
            case "battery_optimization":
                intent = new Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:" + activity.getPackageName())
                );
                break;
            case "notifications":
                intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.getPackageName());
                break;
            default:
                intent = new Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + activity.getPackageName())
                );
                break;
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        activity.startActivity(intent);
    }

    private void startControlledService() {
        if (!com.carriez.flutter_hbb.MainService.Companion.isReady()) {
            requestPermission("screen_capture", true);
            return;
        }
        Intent serviceIntent = new Intent(activity, com.carriez.flutter_hbb.MainService.class);
        serviceIntent.setAction("INIT_MEDIA_PROJECTION_AND_SERVICE");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(serviceIntent);
        } else {
            activity.startService(serviceIntent);
        }
    }

    private void stopControlledService() {
        activity.stopService(new Intent(activity, com.carriez.flutter_hbb.MainService.class));
    }

    private boolean hasNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true;
        }
        return ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean isIgnoringBatteryOptimizations() {
        PowerManager manager = (PowerManager) activity.getSystemService(Context.POWER_SERVICE);
        return manager != null && manager.isIgnoringBatteryOptimizations(activity.getPackageName());
    }

    private boolean isAccessibilityConnected() {
        return com.carriez.flutter_hbb.InputService.Companion.isOpen();
    }

    private boolean isAccessibilitySettingEnabled() {
        String enabledServices = Settings.Secure.getString(
                activity.getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        );
        if (TextUtils.isEmpty(enabledServices)) {
            return false;
        }
        String expectedService = new ComponentName(
                activity,
                com.carriez.flutter_hbb.InputService.class
        ).flattenToString();
        return enabledServices.contains(expectedService);
    }

    private String readString(Object value) {
        return value == null ? "" : value.toString().trim();
    }

    private boolean hasBundledRustdeskController() {
        File nativeDir = new File(activity.getApplicationInfo().nativeLibraryDir);
        File rustdeskLib = new File(nativeDir, "librustdesk.so");
        if (rustdeskLib.exists()) {
            return true;
        }

        String[] apkPaths = buildApkPaths();
        for (String abi : Build.SUPPORTED_ABIS) {
            String entryName = "lib/" + abi + "/librustdesk.so";
            for (String apkPath : apkPaths) {
                if (apkContainsEntry(apkPath, entryName)) {
                    return true;
                }
            }
        }
        return false;
    }

    private String[] buildApkPaths() {
        String sourceDir = activity.getApplicationInfo().sourceDir;
        String[] splitSourceDirs = activity.getApplicationInfo().splitSourceDirs;
        if (splitSourceDirs == null || splitSourceDirs.length == 0) {
            return new String[]{sourceDir};
        }

        String[] paths = new String[splitSourceDirs.length + 1];
        paths[0] = sourceDir;
        System.arraycopy(splitSourceDirs, 0, paths, 1, splitSourceDirs.length);
        return paths;
    }

    private boolean apkContainsEntry(String apkPath, String entryName) {
        if (TextUtils.isEmpty(apkPath)) {
            return false;
        }
        try (ZipFile apk = new ZipFile(apkPath)) {
            return apk.getEntry(entryName) != null;
        } catch (IOException ignored) {
            return false;
        }
    }
}
