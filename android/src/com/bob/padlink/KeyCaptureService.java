package com.bob.padlink;

import android.accessibilityservice.AccessibilityService;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

/**
 * Optional accessibility service that sees hardware keyboard events before Android's system shortcuts do.
 * Without it the Win (Meta) key and Win+key combinations are consumed by the system (all apps, recents,
 * input method switch, ...) and never reach the app. While the Mac display is in front and connected, every
 * key that has a Mac equivalent is sent to the Mac and kept from Android; otherwise keys pass through untouched.
 */
public class KeyCaptureService extends AccessibilityService {
    static volatile boolean running;
    private static KeyCaptureService instance;

    @Override
    protected void onServiceConnected() {
        running = true;
        instance = this;
        setFiltering(PadLinkHub.get(this).isUiVisible());
    }

    /**
     * Key filtering makes Android wait for this service on every key of every keyboard (up to 500 ms if the app
     * is frozen in the background, which then also triggers key repeat). So it is only on while the Mac display
     * is in front. Called on the main thread.
     */
    static void setFilteringIfRunning(boolean on) {
        if (instance != null) instance.setFiltering(on);
    }

    private void setFiltering(boolean on) {
        android.accessibilityservice.AccessibilityServiceInfo info = getServiceInfo();
        if (info == null) return;
        int f = android.accessibilityservice.AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS;
        int flags = on ? info.flags | f : info.flags & ~f;
        if (flags == info.flags) return;
        info.flags = flags;
        setServiceInfo(info);
    }

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        running = false;
        instance = null;
        return super.onUnbind(intent);
    }

    @Override
    protected boolean onKeyEvent(KeyEvent e) {
        PadLinkHub hub = PadLinkHub.get(this);
        Session s = hub.session();
        if (TouchInput.fromBridge(e)) return false;
        if (!hub.isUiVisible() || s == null || s.isClosed() || !s.hasVideo()) return false;
        int mac = KeyMap.macKeyCode(e.getKeyCode());
        if (mac < 0) return false;
        int action = e.getAction();
        if (action == KeyEvent.ACTION_DOWN || action == KeyEvent.ACTION_UP) {
            int extra = mac | (KeyMap.macFlags(e) & 0xFFFF0000);
            s.sendInput(TouchInput.KEY, action == KeyEvent.ACTION_DOWN ? 1 : 0, 0, 0, 0, 0, 0, 0, extra);
        }
        return true;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
    }

    @Override
    public void onInterrupt() {
    }
}
