package com.bob.padlink;

import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.usb.UsbAccessory;
import android.hardware.usb.UsbManager;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.Settings;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Collections;

/**
 * Process-wide connection state, kept alive by PadLinkService:
 * the Wi-Fi listener (+ Bonjour advertisement), the USB accessory link and the current Session.
 * The Mac always initiates over Wi-Fi; "want" in the Bonjour TXT record tells it the user opened
 * the app on the tablet and would like to connect right away.
 */
final class PadLinkHub implements Session.Listener {
    interface Ui {
        void onHubChanged();
        void onVideoConfig(int width, int height);
        void onHud(String text);
    }

    static final int PORT = 27183;
    private static final String TAG = "PadLink";
    private static PadLinkHub instance;

    private final Context app;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean running;
    private ServerSocket serverSocket;
    private volatile Session session;
    private NsdManager.RegistrationListener nsdListener;
    private boolean want;
    private String lastEnd = "";
    private Ui ui;
    private volatile boolean uiVisible;

    static synchronized PadLinkHub get(Context c) {
        if (instance == null) instance = new PadLinkHub(c.getApplicationContext());
        return instance;
    }

    private PadLinkHub(Context app) {
        this.app = app;
    }

    Session session() { return session; }
    String lastEnd() { return lastEnd; }
    boolean isUiVisible() { return uiVisible; }

    /** Leaving the display in the background keeps the Mac's windows in place for a while, then lets go. */
    private final Runnable backgroundTimeout = () -> {
        if (!uiVisible) disconnect("tablet app in background");
    };

    void setUi(Ui ui, boolean visible) {
        this.ui = ui;
        this.uiVisible = visible;
        main.removeCallbacks(backgroundTimeout);
        if (!visible) main.postDelayed(backgroundTimeout, 60_000);
        if (running) addAnchor();   // the overlay permission may have been granted since start()
        KeyCaptureService.setFilteringIfRunning(visible);
    }

    void start() {
        if (running) return;
        running = true;
        new Thread(this::acceptLoop, "padlink-accept").start();
        registerService();
        addAnchor();
    }

    void stop() {
        running = false;
        removeAnchor();
        try {
            if (serverSocket != null) serverSocket.close();
        } catch (IOException ignored) {
        }
        disconnect("service stopped");
        unregisterService();
    }

    /** True while the app is open on the tablet and not connected: the Mac may connect on its own. */
    void setWant(boolean w) {
        if (want == w) return;
        want = w;
        if (running) {
            unregisterService();
            registerService();
        }
    }

    void disconnect(String reason) {
        Session s = session;
        if (s != null) s.close(reason);
    }

    // ---- Wi-Fi ----

    private void acceptLoop() {
        try {
            serverSocket = new ServerSocket();
            serverSocket.setReuseAddress(true);
            serverSocket.bind(new InetSocketAddress(PORT));
            while (running) {
                Socket socket = serverSocket.accept();
                Session cur = session;
                if (cur != null && !cur.isClosed() && cur.usb) {
                    socket.close();   // USB link wins over Wi-Fi
                    continue;
                }
                socket.setTcpNoDelay(true);
                socket.setReceiveBufferSize(1 << 20);
                socket.setTrafficClass(0xA0);
                InputStream in = new BufferedInputStream(socket.getInputStream(), 1 << 16);
                begin(new Session(socket.getInetAddress().getHostAddress(), false, in, socket.getOutputStream(), socket, hello(), this));
            }
        } catch (IOException e) {
            if (running) Log.w(TAG, "server: " + e);
        }
    }

    // ---- USB (Android Open Accessory) ----

    void openAccessory(UsbAccessory accessory) {
        UsbManager um = app.getSystemService(UsbManager.class);
        ParcelFileDescriptor pfd = um.openAccessory(accessory);
        if (pfd == null) {
            Log.w(TAG, "openAccessory failed");
            return;
        }
        InputStream in = new AccessoryInputStream(new FileInputStream(pfd.getFileDescriptor()));
        begin(new Session("USB", true, in, new FileOutputStream(pfd.getFileDescriptor()), pfd, hello(), this));
    }

    private void begin(Session s) {
        Session old = session;
        if (old != null) old.close("replaced by " + (s.usb ? "USB" : s.peer));
        session = s;
        s.start();
        main.post(() -> {
            if (!uiVisible) launchUi();
            notifyUi();
            PadLinkService.refresh(app);
        });
    }

    /**
     * Android 15+ lets an app with "display over other apps" start its UI from the background only while
     * one of its overlay windows is visible; a 1x1 transparent one is enough for the Mac to pop the display up.
     */
    private View anchor;

    void addAnchor() {
        if (anchor != null || !Settings.canDrawOverlays(app)) return;
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(1, 1,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        anchor = new View(app);
        anchor.setBackgroundColor(Color.TRANSPARENT);
        try {
            app.getSystemService(WindowManager.class).addView(anchor, lp);
        } catch (RuntimeException e) {
            Log.w(TAG, "anchor overlay: " + e);
            anchor = null;
        }
    }

    private void removeAnchor() {
        if (anchor == null) return;
        try {
            app.getSystemService(WindowManager.class).removeView(anchor);
        } catch (RuntimeException ignored) {
        }
        anchor = null;
    }

    private void launchUi() {
        Intent i = new Intent(app, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        try {
            app.startActivity(i);
        } catch (RuntimeException e) {
            Log.w(TAG, "cannot bring up the display: " + e);
        }
    }

    private void notifyUi() {
        if (ui != null) ui.onHubChanged();
    }

    // ---- Session.Listener (main thread) ----

    @Override
    public void onSessionEnded(Session s, String reason) {
        if (session == s) {
            session = null;
            lastEnd = reason;
        }
        notifyUi();
        PadLinkService.refresh(app);
    }

    @Override
    public void onVideoConfig(Session s, int width, int height) {
        if (ui != null && session == s) ui.onVideoConfig(width, height);
    }

    @Override
    public void onMacStatus(Session s, String message) {
        notifyUi();
    }

    @Override
    public void onHud(Session s, String text) {
        if (ui != null && session == s) ui.onHud(text);
    }

    @Override
    public void onShowRequested(Session s) {
        if (session == s && !uiVisible) launchUi();
    }

    // ---- Bonjour ----

    private void registerService() {
        String ip = wifiAddress();
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(deviceName(app));
        info.setServiceType("_padlink._tcp");
        info.setPort(PORT);
        if (ip != null) info.setAttribute("ip", ip);
        info.setAttribute("port", String.valueOf(PORT));
        info.setAttribute("want", want ? "1" : "0");
        nsdListener = new NsdManager.RegistrationListener() {
            @Override public void onRegistrationFailed(NsdServiceInfo s, int code) { Log.w(TAG, "nsd register failed " + code); }
            @Override public void onUnregistrationFailed(NsdServiceInfo s, int code) { }
            @Override public void onServiceRegistered(NsdServiceInfo s) { Log.i(TAG, "nsd registered " + s.getServiceName() + " want=" + want); }
            @Override public void onServiceUnregistered(NsdServiceInfo s) { }
        };
        try {
            app.getSystemService(NsdManager.class).registerService(info, NsdManager.PROTOCOL_DNS_SD, nsdListener);
        } catch (RuntimeException e) {
            Log.w(TAG, "nsd: " + e);
        }
    }

    private void unregisterService() {
        if (nsdListener == null) return;
        try {
            app.getSystemService(NsdManager.class).unregisterService(nsdListener);
        } catch (RuntimeException ignored) {
        }
        nsdListener = null;
    }

    // ---- Device info ----

    static String wifiAddress() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback() || !ni.getName().startsWith("wlan")) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address && a.isSiteLocalAddress()) return a.getHostAddress();
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    static String deviceName(Context c) {
        String n = Settings.Global.getString(c.getContentResolver(), Settings.Global.DEVICE_NAME);
        return n != null && !n.isEmpty() ? n : Build.MODEL;
    }

    private JSONObject hello() {
        JSONObject j = new JSONObject();
        Display d = app.getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY);
        Display.Mode m = d.getMode();
        DisplayMetrics dm = app.getResources().getDisplayMetrics();
        float maxHz = 0;
        for (Display.Mode x : d.getSupportedModes()) maxHz = Math.max(maxHz, x.getRefreshRate());
        try {
            j.put("proto", 1);
            j.put("name", deviceName(app));
            j.put("model", Build.MODEL);
            j.put("width", Math.max(m.getPhysicalWidth(), m.getPhysicalHeight()));
            j.put("height", Math.min(m.getPhysicalWidth(), m.getPhysicalHeight()));
            j.put("xdpi", (double) Math.max(dm.xdpi, dm.ydpi));
            j.put("ydpi", (double) Math.min(dm.xdpi, dm.ydpi));
            j.put("refresh", (double) maxHz);
            JSONArray codecs = new JSONArray();
            if (VideoDecoder.hasDecoder("video/avc")) codecs.put("video/avc");
            if (VideoDecoder.hasDecoder("video/hevc")) codecs.put("video/hevc");
            j.put("codecs", codecs);
        } catch (JSONException ignored) {
        }
        return j;
    }

    /** USB accessory reads must use 16 KB requests (the gadget driver's bulk buffer size). */
    static final class AccessoryInputStream extends InputStream {
        private final FileInputStream in;
        private final byte[] buf = new byte[16384];
        private int pos, len;

        AccessoryInputStream(FileInputStream in) {
            this.in = in;
        }

        private boolean fill() throws IOException {
            while (pos >= len) {
                int n = in.read(buf, 0, buf.length);
                if (n < 0) return false;
                pos = 0;
                len = n;
            }
            return true;
        }

        @Override
        public int read() throws IOException {
            return fill() ? buf[pos++] & 0xff : -1;
        }

        @Override
        public int read(byte[] b, int off, int n) throws IOException {
            if (n == 0) return 0;
            if (!fill()) return -1;
            int k = Math.min(n, len - pos);
            System.arraycopy(buf, pos, b, off, k);
            pos += k;
            return k;
        }
    }
}
