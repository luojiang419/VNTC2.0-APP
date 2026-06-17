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
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class RemoteAssistAndroidBridge {
    private static final String CHANNEL = "top.wherewego.vnt/remote_assist_android";

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
        boolean screenCaptureGranted = RemoteAssistStateHolder.hasMediaProjectionPermission();
        boolean accessibilityGranted = isAccessibilityEnabled();
        boolean overlayGranted = Settings.canDrawOverlays(activity);
        boolean batteryOptimizationIgnored = isIgnoringBatteryOptimizations();
        boolean controllerAvailable = hasBundledRustdeskController();
        boolean controlledServiceRunning = RemoteAssistControlledService.isRunning();
        status.put("notificationPermissionGranted", hasNotificationPermission());
        status.put("screenCapturePermissionGranted", screenCaptureGranted);
        status.put("accessibilityPermissionGranted", accessibilityGranted);
        status.put("overlayPermissionGranted", overlayGranted);
        status.put("batteryOptimizationIgnored", batteryOptimizationIgnored);
        status.put("controllerAvailable", controllerAvailable);
        status.put("controlledRoleSupported", true);
        status.put("controlledRuntimeReady", controlledServiceRunning);
        status.put("controlledServiceRunning", controlledServiceRunning);
        status.put(
                "permissionsReady",
                notificationGranted
                        && screenCaptureGranted
                        && accessibilityGranted
                        && overlayGranted
                        && batteryOptimizationIgnored
        );
        status.put("listenerReady", controlledServiceRunning);
        status.put("runtimeVersion", "android-integrated-v3");
        status.put("runtimeAvailable", true);
        status.put("serviceInstalled", true);
        status.put("serviceRunning", controlledServiceRunning);
        status.put("portListening", controlledServiceRunning);
        return status;
    }

    private void requestPermission(String permission, boolean startServiceAfterGrant) {
        switch (permission) {
            case "screen_capture":
                Intent intent = new Intent(activity, RemoteAssistScreenCaptureActivity.class);
                intent.putExtra(RemoteAssistScreenCaptureActivity.EXTRA_START_SERVICE,
                        startServiceAfterGrant);
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
        if (!RemoteAssistStateHolder.hasMediaProjectionPermission()) {
            requestPermission("screen_capture", true);
            return;
        }
        Intent serviceIntent = new Intent(activity, RemoteAssistControlledService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(serviceIntent);
        } else {
            activity.startService(serviceIntent);
        }
    }

    private void stopControlledService() {
        activity.stopService(new Intent(activity, RemoteAssistControlledService.class));
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

    private boolean isAccessibilityEnabled() {
        String enabledServices = Settings.Secure.getString(
                activity.getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        );
        if (TextUtils.isEmpty(enabledServices)) {
            return RemoteAssistInputService.isRunning();
        }
        String expectedService = new ComponentName(
                activity,
                RemoteAssistInputService.class
        ).flattenToString();
        return enabledServices.contains(expectedService) || RemoteAssistInputService.isRunning();
    }

    private String readString(Object value) {
        return value == null ? "" : value.toString().trim();
    }

    private boolean hasBundledRustdeskController() {
        File nativeDir = new File(activity.getApplicationInfo().nativeLibraryDir);
        File rustdeskLib = new File(nativeDir, "librustdesk.so");
        return rustdeskLib.exists();
    }
}
