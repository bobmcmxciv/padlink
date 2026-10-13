package com.bob.padlink;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.hardware.usb.UsbAccessory;
import android.hardware.usb.UsbManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.PointerIcon;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.Toast;
import android.window.OnBackInvokedDispatcher;

import java.util.ArrayList;
import java.util.List;

/** Full-screen Mac display: shows the video of the current session and forwards touch / pen / keys. */
public class MainActivity extends Activity implements SurfaceHolder.Callback, PadLinkHub.Ui {
    private PadLinkHub hub;
    private FrameLayout root;
    private SurfaceView surfaceView;
    private TextView statusView;
    private TextView hudView;
    private TouchInput touch;
    private WifiManager.WifiLock wifiLock;
    private boolean surfaceReady, resumed, hudOn;
    private Session attached;
    private long lastBackMs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        hub = PadLinkHub.get(this);
        PadLinkService.start(this);

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        lp.preferredDisplayModeId = highestRefreshMode();
        getWindow().setAttributes(lp);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));

        statusView = new TextView(this);
        statusView.setTextColor(Color.WHITE);
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        statusView.setGravity(Gravity.CENTER);
        statusView.setLineSpacing(0, 1.3f);
        statusView.setPadding(48, 32, 48, 32);
        statusView.setBackgroundColor(0xCC111111);
        root.addView(statusView, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        hudView = new TextView(this);
        hudView.setTextColor(0xFF9CFF9C);
        hudView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        hudView.setTypeface(Typeface.MONOSPACE);
        hudView.setPadding(24, 16, 24, 16);
        hudView.setBackgroundColor(0xAA000000);
        hudView.setVisibility(View.GONE);
        root.addView(hudView, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.END));
        setContentView(root);

        touch = new TouchInput(surfaceView, (kind, button, phase, momentum, x, y, a, b, extra) -> {
            Session s = hub.session();
            if (s != null) s.sendInput(kind, button, phase, momentum, x, y, a, b, extra);
        }, this::toggleHud);
        surfaceView.setOnTouchListener((v, e) -> touch.onTouch(e));
        surfaceView.setOnHoverListener((v, e) -> touch.onHover(e));
        surfaceView.setOnGenericMotionListener((v, e) -> touch.onGenericMotion(e));
        // The Mac draws its own cursor into the video; hide Android's pointer for mouse / stylus hover.
        surfaceView.setPointerIcon(PointerIcon.getSystemIcon(this, PointerIcon.TYPE_NULL));

        WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "padlink");
        wifiLock.setReferenceCounted(false);

        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::onBackGesture);
        }
        handleIntent(getIntent());
    }

    /** Edge swipes are common while dragging windows; require a second back gesture to leave. */
    private void onBackGesture() {
        long now = System.currentTimeMillis();
        if (now - lastBackMs < 2000) {
            hub.disconnect("closed on tablet");
            finish();
        } else {
            lastBackMs = now;
            Toast.makeText(this, "再返回一次断开并退出 Mac 副屏", Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {   // Android 12 / 12L
        onBackGesture();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleIntent(intent);
    }

    private void handleIntent(Intent intent) {
        if (intent != null && UsbManager.ACTION_USB_ACCESSORY_ATTACHED.equals(intent.getAction())) {
            @SuppressWarnings("deprecation")
            UsbAccessory acc = Build.VERSION.SDK_INT >= 33
                    ? intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory.class)
                    : intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY);
            if (acc != null) hub.openAccessory(acc);
        }
    }

    /** The cable is still in accessory mode from an earlier session: pick it up again. */
    private void reopenAccessory() {
        UsbManager um = getSystemService(UsbManager.class);
        UsbAccessory[] list = um.getAccessoryList();
        if (list == null) return;
        for (UsbAccessory a : list) {
            if ("PadLink".equals(a.getManufacturer()) && um.hasPermission(a)) {
                hub.openAccessory(a);
                return;
            }
        }
    }

    private int highestRefreshMode() {
        Display d = getDisplay();
        if (d == null) return 0;
        Display.Mode cur = d.getMode();
        Display.Mode best = cur;
        for (Display.Mode m : d.getSupportedModes()) {
            if (m.getPhysicalWidth() == cur.getPhysicalWidth() && m.getPhysicalHeight() == cur.getPhysicalHeight()
                    && m.getRefreshRate() > best.getRefreshRate() && m.getRefreshRate() <= 121) {
                best = m;
            }
        }
        return best.getModeId();
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        hub.setUi(this, true);
        hideSystemBars();
        wifiLock.acquire();
        if (hub.session() == null) reopenAccessory();
        onHubChanged();
    }

    @Override
    protected void onPause() {
        super.onPause();
        resumed = false;
        hub.setUi(this, false);
        hub.setWant(false);
        touch.stopMomentum();
        detachVideo();
        if (wifiLock.isHeld()) wifiLock.release();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    private void hideSystemBars() {
        WindowInsetsController c = getWindow().getInsetsController();
        if (c != null) {
            c.hide(WindowInsets.Type.systemBars());
            c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    // ---- Surface ----

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        surfaceReady = true;
        onHubChanged();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        List<Rect> rects = new ArrayList<>();
        float density = getResources().getDisplayMetrics().density;
        int edge = (int) (40 * density);
        int h = Math.min(height, (int) (200 * density));
        int top = (height - h) / 2;
        rects.add(new Rect(0, top, edge, top + h));
        rects.add(new Rect(width - edge, top, width, top + h));
        surfaceView.setSystemGestureExclusionRects(rects);
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        detachVideo();
    }

    private void detachVideo() {
        if (attached != null) attached.detachSurface();
        attached = null;
    }

    // ---- PadLinkHub.Ui ----

    @Override
    public void onHubChanged() {
        Session s = hub.session();
        if (s != null && s.isClosed()) s = null;
        if (attached != s) detachVideo();
        if (s != null && attached == null && surfaceReady && resumed) {
            attached = s;
            s.attachSurface(surfaceView.getHolder().getSurface());
        }
        if (s != null && s.hasVideo()) fitVideo(s.videoWidth(), s.videoHeight());
        hub.setWant(resumed && s == null);
        updateStatus(s);
    }

    @Override
    public void onVideoConfig(int width, int height) {
        fitVideo(width, height);
        updateStatus(hub.session());
    }

    @Override
    public void onHud(String text) {
        hudView.setText(text);
    }

    private void fitVideo(int width, int height) {
        int rw = root.getWidth(), rh = root.getHeight();
        if (rw <= 0 || rh <= 0) return;
        float scale = Math.min(rw / (float) width, rh / (float) height);
        int w = Math.round(width * scale), h = Math.round(height * scale);
        FrameLayout.LayoutParams cur = (FrameLayout.LayoutParams) surfaceView.getLayoutParams();
        if (cur.width != w || cur.height != h) {
            surfaceView.setLayoutParams(new FrameLayout.LayoutParams(w, h, Gravity.CENTER));
        }
    }

    private void toggleHud() {
        hudOn = !hudOn;
        hudView.setVisibility(hudOn ? View.VISIBLE : View.GONE);
    }

    private void updateStatus(Session s) {
        String text;
        if (s != null && s.hasVideo()) {
            text = s.macStatus();
        } else if (s != null) {
            text = "已连接 Mac（" + (s.usb ? "USB" : "Wi-Fi") + "），正在建立副屏…" + (s.macStatus().isEmpty() ? "" : "\n\n" + s.macStatus());
        } else {
            String ip = PadLinkHub.wifiAddress();
            String end = hub.lastEnd();
            text = "Mac 副屏\n\n等待 Mac 连接…\n本机 " + (ip != null ? ip : "（未连接 Wi-Fi）")
                    + "\nMac 上的 PadLink 会自动连接；也可用 USB 线直连"
                    + (android.provider.Settings.canDrawOverlays(this) ? ""
                        : "\n\n提示：允许本应用「显示在其他应用的上层」后，\nMac 菜单栏选中本机即可直接唤出副屏")
                    + (KeyCaptureService.running || getResources().getConfiguration().keyboard != android.content.res.Configuration.KEYBOARD_QWERTY ? ""
                        : "\n\n提示：在 设置 → 无障碍 中打开「Mac 副屏键盘」，\n键盘的 Win 键即可作为 Mac 的 Command 使用")
                    + (end.isEmpty() ? "" : "\n\n上次断开：" + end);
        }
        statusView.setText(text);
        statusView.setVisibility(text.isEmpty() ? View.GONE : View.VISIBLE);
    }

    // ---- Hardware keyboard -> Mac ----

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        int mac = KeyMap.macKeyCode(e.getKeyCode());
        Session s = hub.session();
        if (TouchInput.fromBridge(e)) return super.dispatchKeyEvent(e);
        if (mac < 0 || s == null || !s.hasVideo()) return super.dispatchKeyEvent(e);
        int action = e.getAction();
        if (action == KeyEvent.ACTION_DOWN || action == KeyEvent.ACTION_UP) {
            int extra = mac | (KeyMap.macFlags(e) & 0xFFFF0000);
            s.sendInput(TouchInput.KEY, action == KeyEvent.ACTION_DOWN ? 1 : 0, 0, 0, 0, 0, 0, 0, extra);
        }
        return true;
    }
}
