package top.wherewego.vnt_app;

import android.Manifest;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Environment;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;
import android.view.WindowManager;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import top.wherewego.vnt_app.vpn.DeviceConfig;
import top.wherewego.vnt_app.vpn.MyVpnService;

public class MainActivity extends FlutterActivity {
    private static final String TAG = "MainActivity";
    private static final int VPN_REQUEST_CODE = 1;
    private static final int CREATE_FILE_REQUEST_CODE = 2;
    private static final int NOTIFICATION_PERMISSION_REQUEST_CODE = 3;
    private static final int RUSTDESK_PERMISSION_REQUEST_CODE = 4;
    private static final int RUSTDESK_OVERLAY_PERMISSION_REQUEST_CODE = 5;
    private static final int RUSTDESK_MANAGE_STORAGE_PERMISSION_REQUEST_CODE = 6;

    private static final String FILE_CHANNEL = "top.wherewego.vnt/file";
    private static final String RUSTDESK_CHANNEL = "mChannel";
    private static final String RUSTDESK_KEY_SHARED_PREFERENCES = "KEY_SHARED_PREFERENCES";
    private static final String RUSTDESK_KEY_START_ON_BOOT_OPT = "KEY_START_ON_BOOT_OPT";
    private static final String RUSTDESK_KEY_APP_DIR_CONFIG_PATH = "KEY_APP_DIR_CONFIG_PATH";
    private static final String RUSTDESK_KEY_IS_SUPPORT_VOICE_CALL = "KEY_IS_SUPPORT_VOICE_CALL";
    private static volatile MethodChannel rustdeskEventChannel;
    private MethodChannel fileChannel;
    private MethodChannel rustdeskChannel;
    private String pendingFilePath;
    private MethodChannel.Result pendingFileResult;
    private String pendingRustdeskPermission;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 设置应用上下文，用于更新磁贴和小组件
        FlutterMethodChannel.setAppContext(this);

        // Android 13+ 需要先请求通知权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestNotificationPermission();
        } else {
            // Android 13 以下直接启动通知服务
            startNotificationService();
        }
    }

    /**
     * 请求通知权限（Android 13+）
     */
    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                // 请求通知权限
                ActivityCompat.requestPermissions(this,
                        new String[]{Manifest.permission.POST_NOTIFICATIONS},
                        NOTIFICATION_PERMISSION_REQUEST_CODE);
            } else {
                // 已有权限，启动通知服务
                startNotificationService();
            }
        }
    }

    /**
     * 处理权限请求结果
     */
    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == RUSTDESK_PERMISSION_REQUEST_CODE) {
            final String permission = !TextUtils.isEmpty(pendingRustdeskPermission)
                    ? pendingRustdeskPermission
                    : (permissions.length > 0 ? permissions[0] : "");
            final boolean granted = grantResults.length > 0
                    && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            notifyRustdeskPermissionResult(permission, granted);
            return;
        }
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "通知权限已授予，启动通知服务");
                startNotificationService();
            } else {
                Log.w(TAG, "通知权限被拒绝，跳过通知服务启动");
                // 即使没有通知权限，应用也应该能正常运行
            }
        }
    }

    /**
     * 启动常驻通知服务
     */
    private void startNotificationService() {
        try {
            Intent serviceIntent = new Intent(this, VntNotificationService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Android 8.0+ 使用 startForegroundService
                startForegroundService(serviceIntent);
            } else {
                startService(serviceIntent);
            }
            Log.d(TAG, "常驻通知服务已启动");
        } catch (Exception e) {
            Log.e(TAG, "启动通知服务失败: " + e.getMessage(), e);
            // 不要让通知服务启动失败阻止应用运行
        }
    }

    private boolean isRustdeskPermissionGranted(@NonNull String permission) {
        if (TextUtils.isEmpty(permission)) {
            return false;
        }
        if (Manifest.permission.SYSTEM_ALERT_WINDOW.equals(permission)) {
            return Settings.canDrawOverlays(this);
        }
        if (Manifest.permission.MANAGE_EXTERNAL_STORAGE.equals(permission)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return Environment.isExternalStorageManager();
            }
            return true;
        }
        if (Manifest.permission.POST_NOTIFICATIONS.equals(permission)
                && Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true;
        }
        return ContextCompat.checkSelfPermission(this, permission)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestRustdeskPermission(@NonNull String permission) {
        if (isRustdeskPermissionGranted(permission)) {
            notifyRustdeskPermissionResult(permission, true);
            return;
        }

        pendingRustdeskPermission = permission;

        if (Manifest.permission.SYSTEM_ALERT_WINDOW.equals(permission)) {
            Intent intent = new Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())
            );
            startActivityForResult(intent, RUSTDESK_OVERLAY_PERMISSION_REQUEST_CODE);
            return;
        }

        if (Manifest.permission.MANAGE_EXTERNAL_STORAGE.equals(permission)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:" + getPackageName())
                );
                if (intent.resolveActivity(getPackageManager()) == null) {
                    intent = new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
                }
                startActivityForResult(intent, RUSTDESK_MANAGE_STORAGE_PERMISSION_REQUEST_CODE);
            } else {
                notifyRustdeskPermissionResult(permission, true);
            }
            return;
        }

        ActivityCompat.requestPermissions(
                this,
                new String[]{permission},
                RUSTDESK_PERMISSION_REQUEST_CODE
        );
    }

    private void notifyRustdeskPermissionResult(String permission, boolean granted) {
        pendingRustdeskPermission = null;
        if (rustdeskChannel == null || TextUtils.isEmpty(permission)) {
            return;
        }
        Map<String, Object> payload = new HashMap<>();
        payload.put("type", permission);
        payload.put("result", granted);
        rustdeskChannel.invokeMethod("on_android_permission_result", payload);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        // VPN Channel
        FlutterMethodChannel.init(flutterEngine, new FlutterMethodChannel.Callback() {
            @Override
            public int startVpn(DeviceConfig config) {
                startVpnService(config);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    MyTileService.setState(true);
                }
                return 0;
            }

            @Override
            public void stopVpn() {
                MyVpnService.stopVpn();
            }

            @Override
            public void moveToBack() {
                moveTaskToBack(true);
            }
        });

        // Flutter 初始化完成后，立即更新通知服务状态
        VntNotificationService.updateNotification(this);

        // File Channel - 用于文件保存
        fileChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), FILE_CHANNEL);
        fileChannel.setMethodCallHandler((call, result) -> {
            if (call.method.equals("saveFile")) {
                String filePath = call.argument("filePath");
                String fileName = call.argument("fileName");
                String mimeType = call.argument("mimeType");

                if (filePath == null || fileName == null) {
                    result.error("INVALID_ARGUMENT", "filePath and fileName are required", null);
                    return;
                }

                pendingFilePath = filePath;
                pendingFileResult = result;

                // 使用 SAF 创建文件
                createFile(fileName, mimeType != null ? mimeType : "*/*");
            } else {
                result.notImplemented();
            }
        });

        rustdeskChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                RUSTDESK_CHANNEL
        );
        rustdeskChannel.setMethodCallHandler(this::handleRustdeskMethodCall);
        rustdeskEventChannel = rustdeskChannel;

    }

    public static void notifyRustdeskMethod(String method, @Nullable Object arguments) {
        if (rustdeskEventChannel == null) {
            return;
        }
        rustdeskEventChannel.invokeMethod(method, arguments);
    }

    public static void notifyRustdeskStateChange(String name, boolean value) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("name", name);
        payload.put("value", value ? "true" : "false");
        notifyRustdeskMethod("on_state_changed", payload);
    }

    private void handleRustdeskMethodCall(
            @NonNull io.flutter.plugin.common.MethodCall call,
            @NonNull MethodChannel.Result result
    ) {
        try {
            switch (call.method) {
                case "enable_soft_keyboard":
                    final Object enableArg = call.arguments;
                    final boolean enableSoftKeyboard = !(enableArg instanceof Boolean)
                            || (Boolean) enableArg;
                    if (enableSoftKeyboard) {
                        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM);
                    } else {
                        getWindow().addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM);
                    }
                    result.success(true);
                    return;
                case "try_sync_clipboard":
                    // 当前单 APK 方案先保证远控会话链路可用，剪贴板同步后续再补完整宿主桥接。
                    result.success(true);
                    return;
                case "get_value":
                    if (RUSTDESK_KEY_IS_SUPPORT_VOICE_CALL.equals(call.arguments)) {
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R);
                    } else {
                        result.success(false);
                    }
                    return;
                case "get_start_on_boot_opt":
                    result.success(
                            getSharedPreferences(RUSTDESK_KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                                    .getBoolean(RUSTDESK_KEY_START_ON_BOOT_OPT, false)
                    );
                    return;
                case "set_start_on_boot_opt":
                    if (call.arguments instanceof Boolean) {
                        getSharedPreferences(RUSTDESK_KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                                .edit()
                                .putBoolean(
                                        RUSTDESK_KEY_START_ON_BOOT_OPT,
                                        (Boolean) call.arguments
                                )
                                .apply();
                        result.success(true);
                    } else {
                        result.success(false);
                    }
                    return;
                case "sync_app_dir":
                    if (call.arguments instanceof String) {
                        getSharedPreferences(RUSTDESK_KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                                .edit()
                                .putString(
                                        RUSTDESK_KEY_APP_DIR_CONFIG_PATH,
                                        (String) call.arguments
                                )
                                .apply();
                        result.success(true);
                    } else {
                        result.success(false);
                    }
                    return;
                case "check_permission":
                    if (call.arguments instanceof String) {
                        result.success(isRustdeskPermissionGranted((String) call.arguments));
                    } else {
                        result.success(false);
                    }
                    return;
                case "request_permission":
                    if (call.arguments instanceof String) {
                        requestRustdeskPermission((String) call.arguments);
                        result.success(true);
                    } else {
                        result.success(false);
                    }
                    return;
                case "start_action":
                    if (call.arguments instanceof String) {
                        launchRustdeskAction((String) call.arguments);
                        result.success(true);
                    } else {
                        result.success(false);
                    }
                    return;
                case "init_service":
                    startRustdeskControlledService(true);
                    result.success(true);
                    return;
                case "check_service":
                    notifyRustdeskServiceState();
                    result.success(true);
                    return;
                case "stop_input":
                    notifyRustdeskStateChange("input", isRustdeskInputEnabled());
                    result.success(true);
                    return;
                case "cancel_notification":
                case "on_voice_call_started":
                case "on_voice_call_closed":
                    result.success(true);
                    return;
                case "start_capture":
                    startRustdeskControlledService(false);
                    result.success(true);
                    return;
                case "stop_service":
                    stopRustdeskControlledService();
                    result.success(true);
                    return;
                default:
                    result.notImplemented();
            }
        } catch (Exception error) {
            result.error("RUSTDESK_CHANNEL_ERROR", error.getMessage(), null);
        }
    }

    private boolean isRustdeskInputEnabled() {
        String enabledServices = Settings.Secure.getString(
                getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        );
        if (TextUtils.isEmpty(enabledServices)) {
            return RemoteAssistInputService.isRunning();
        }
        String expectedService = new ComponentName(
                this,
                RemoteAssistInputService.class
        ).flattenToString();
        return enabledServices.contains(expectedService) || RemoteAssistInputService.isRunning();
    }

    private void notifyRustdeskServiceState() {
        notifyRustdeskStateChange("media", RemoteAssistStateHolder.hasMediaProjectionPermission());
        notifyRustdeskStateChange("input", isRustdeskInputEnabled());
    }

    private void startRustdeskControlledService(boolean requestPermissionIfNeeded) {
        if (!RemoteAssistStateHolder.hasMediaProjectionPermission()) {
            notifyRustdeskStateChange("media", false);
            notifyRustdeskStateChange("input", isRustdeskInputEnabled());
            if (requestPermissionIfNeeded) {
                Intent intent = new Intent(this, RemoteAssistScreenCaptureActivity.class);
                intent.putExtra(RemoteAssistScreenCaptureActivity.EXTRA_START_SERVICE, true);
                startActivity(intent);
            }
            return;
        }

        Intent serviceIntent = new Intent(this, RemoteAssistControlledService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }
        notifyRustdeskServiceState();
    }

    private void stopRustdeskControlledService() {
        stopService(new Intent(this, RemoteAssistControlledService.class));
        notifyRustdeskStateChange("media", false);
        notifyRustdeskStateChange("input", isRustdeskInputEnabled());
    }

    private void launchRustdeskAction(String action) {
        try {
            Intent intent = new Intent(action);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (!android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS.equals(action)) {
                intent.setData(Uri.parse("package:" + getPackageName()));
            }
            startActivity(intent);
        } catch (Exception error) {
            Log.w(TAG, "打开 RustDesk 宿主动作失败: " + action, error);
        }
    }

    private void createFile(String fileName, String mimeType) {
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType(mimeType);
        intent.putExtra(Intent.EXTRA_TITLE, fileName);

        startActivityForResult(intent, CREATE_FILE_REQUEST_CODE);
    }

    private void startVpnService(DeviceConfig config) {
        MyVpnService.pendingConfig = config;
        // 每次启动都重新检查权限，这样如果有其他 VPN 运行，系统会弹窗让用户选择
        Intent intent = VpnService.prepare(this);
        if (intent != null) {
            // 需要用户授权，系统会提示断开其他 VPN
            startActivityForResult(intent, VPN_REQUEST_CODE);
        } else {
            // 已有权限，直接启动
            Intent serviceIntent = new Intent(this, MyVpnService.class);
            startService(serviceIntent);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == RUSTDESK_OVERLAY_PERMISSION_REQUEST_CODE
                || requestCode == RUSTDESK_MANAGE_STORAGE_PERMISSION_REQUEST_CODE) {
            final String permission = pendingRustdeskPermission;
            notifyRustdeskPermissionResult(
                    permission,
                    permission != null && isRustdeskPermissionGranted(permission)
            );
        } else if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                Intent serviceIntent = new Intent(this, MyVpnService.class);
                startService(serviceIntent);
            } else {
                FlutterMethodChannel.callError("User denied VPN authorization", null);
            }
        } else if (requestCode == CREATE_FILE_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data != null) {
                Uri uri = data.getData();
                if (uri != null && pendingFilePath != null) {
                    // 复制文件到用户选择的位置
                    copyFileToUri(pendingFilePath, uri);
                } else {
                    if (pendingFileResult != null) {
                        pendingFileResult.error("SAVE_FAILED", "Failed to get URI", null);
                        pendingFileResult = null;
                    }
                }
            } else {
                // 用户取消
                if (pendingFileResult != null) {
                    pendingFileResult.success(null);
                    pendingFileResult = null;
                }
            }
            pendingFilePath = null;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    private void copyFileToUri(String sourcePath, Uri destUri) {
        try {
            File sourceFile = new File(sourcePath);
            FileInputStream inputStream = new FileInputStream(sourceFile);
            OutputStream outputStream = getContentResolver().openOutputStream(destUri);

            if (outputStream == null) {
                throw new Exception("Cannot open output stream");
            }

            byte[] buffer = new byte[4096];
            int length;
            while ((length = inputStream.read(buffer)) > 0) {
                outputStream.write(buffer, 0, length);
            }

            outputStream.flush();
            outputStream.close();
            inputStream.close();

            if (pendingFileResult != null) {
                pendingFileResult.success(destUri.toString());
                pendingFileResult = null;
            }

            Log.d(TAG, "File saved successfully to: " + destUri.toString());
        } catch (Exception e) {
            Log.e(TAG, "Error saving file", e);
            if (pendingFileResult != null) {
                pendingFileResult.error("SAVE_FAILED", e.getMessage(), null);
                pendingFileResult = null;
            }
        }
    }
}
