package top.wherewego.vnt_app;

import android.content.Intent;

final class RemoteAssistStateHolder {
    private static Intent mediaProjectionData;
    private static int mediaProjectionResultCode;
    private static String accessPassword = "";

    private RemoteAssistStateHolder() {
    }

    static synchronized void setMediaProjectionPermission(int resultCode, Intent data) {
        mediaProjectionResultCode = resultCode;
        mediaProjectionData = data;
    }

    static synchronized Intent getMediaProjectionData() {
        return mediaProjectionData;
    }

    static synchronized int getMediaProjectionResultCode() {
        return mediaProjectionResultCode;
    }

    static synchronized boolean hasMediaProjectionPermission() {
        return mediaProjectionData != null;
    }

    static synchronized void clearMediaProjectionPermission() {
        mediaProjectionData = null;
        mediaProjectionResultCode = 0;
    }

    static synchronized void setAccessPassword(String password) {
        accessPassword = password == null ? "" : password;
    }

    static synchronized String getAccessPassword() {
        return accessPassword;
    }
}
