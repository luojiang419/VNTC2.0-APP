package top.wherewego.vnt_app;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;

public class RemoteAssistInputService extends AccessibilityService {
    private static volatile boolean running = false;

    public static boolean isRunning() {
        return running;
    }

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        running = true;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // 当前版本只负责权限链路与运行态托管，输入注入能力后续接入。
    }

    @Override
    public void onInterrupt() {
        // no-op
    }

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        running = false;
        return super.onUnbind(intent);
    }
}
