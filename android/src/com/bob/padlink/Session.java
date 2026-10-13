package com.bob.padlink;

import android.media.MediaCodec;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Locale;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * One connection to the Mac host, over Wi-Fi (TCP) or USB (Android Open Accessory).
 * The video surface can come and go (app in background) without dropping the connection;
 * a fresh decoder asks the Mac for a keyframe.
 */
final class Session implements VideoDecoder.Listener {
    interface Listener {
        void onSessionEnded(Session s, String reason);
        void onVideoConfig(Session s, int width, int height);
        void onMacStatus(Session s, String message);
        void onHud(Session s, String text);
        void onShowRequested(Session s);
    }

    private static final String TAG = "PadLink";
    // tablet -> mac
    static final int MSG_HELLO = 0x01, MSG_INPUT = 0x02, MSG_PING = 0x03, MSG_STATS = 0x04, MSG_KEYFRAME = 0x05;
    // mac -> tablet
    static final int MSG_CONFIG = 0x81, MSG_FRAME = 0x82, MSG_PONG = 0x83, MSG_STATUS = 0x84, MSG_SHOW = 0x85, MSG_HELLO_REQUEST = 0x86;

    final String peer;
    final boolean usb;
    private final InputStream input;
    private final OutputStream output;
    private final Closeable closer;
    private final JSONObject hello;
    private final Listener listener;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final LinkedBlockingQueue<byte[]> sendQueue = new LinkedBlockingQueue<>();
    private volatile boolean closed;

    // Video: decoder exists only while a surface is attached.
    private final Object decoderLock = new Object();
    private Surface surface;
    private VideoDecoder decoder;
    private String mime;
    private volatile int videoW, videoH;
    private int fps = 60;
    private byte[] frameBuf = new byte[1 << 20];
    private byte[] pendingConfig;
    private boolean decoderHasConfig, haveKeyframe;
    private long lastKeyRequestNs;
    private volatile String macStatus = "";

    // Clock sync: macTime ~= nanoTime + offset, from the lowest-RTT ping in a sliding window.
    private volatile long clockOffsetNs;
    private long bestRttNs = Long.MAX_VALUE, bestRttAt;
    private volatile long lastRttNs;

    // Per-frame timing, indexed by presentation time (= Mac capture time in microseconds).
    private final long[] ringPts = new long[256], ringSend = new long[256], ringRecv = new long[256];
    private final ArrayList<long[]> samples = new ArrayList<>();
    private long statBytes, statSince = System.nanoTime();

    Session(String peer, boolean usb, InputStream in, OutputStream out, Closeable closer, JSONObject hello, Listener listener) {
        this.peer = peer;
        this.usb = usb;
        this.input = in;
        this.output = out;
        this.closer = closer;
        // A session id lets the Mac tell a restarted tablet app (new session, same link) from a repeated hello.
        JSONObject h = hello;
        try {
            h = new JSONObject(hello.toString()).put("session", System.currentTimeMillis());
        } catch (JSONException ignored) {
        }
        this.hello = h;
        this.listener = listener;
    }

    boolean isClosed() { return closed; }
    boolean hasVideo() { return videoW > 0; }
    int videoWidth() { return videoW; }
    int videoHeight() { return videoH; }
    String macStatus() { return macStatus; }

    void start() {
        new Thread(this::writeLoop, "padlink-writer").start();
        Thread reader = new Thread(this::readLoop, "padlink-reader");
        reader.setPriority(Thread.MAX_PRIORITY);
        reader.start();
        new Thread(this::pingLoop, "padlink-ping").start();
        send(MSG_HELLO, hello.toString().getBytes(StandardCharsets.UTF_8));
    }

    void close(String reason) {
        if (closed) return;
        closed = true;
        Log.i(TAG, "session " + peer + " closed: " + reason);
        try {
            closer.close();
        } catch (IOException ignored) {
        }
        sendQueue.offer(new byte[0]);
        synchronized (decoderLock) {
            if (decoder != null) decoder.release();
            decoder = null;
        }
        ui.post(() -> listener.onSessionEnded(this, reason));
    }

    // ---- Surface ----

    void attachSurface(Surface s) {
        synchronized (decoderLock) {
            surface = s;
            startDecoderLocked();
        }
    }

    void detachSurface() {
        synchronized (decoderLock) {
            surface = null;
            if (decoder != null) decoder.release();
            decoder = null;
        }
    }

    private void startDecoderLocked() {
        if (decoder != null || surface == null || mime == null || closed) return;
        try {
            decoder = new VideoDecoder(surface, this);
            decoder.configure(mime, videoW, videoH, fps);
            decoderHasConfig = false;
            haveKeyframe = false;
            lastKeyRequestNs = 0;
            requestKeyframe();
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "decoder: " + e);
            decoder = null;
        }
    }

    // ---- Sending ----

    /** 24-byte input event, see InputInjector.swift on the Mac side. */
    void sendInput(int kind, int button, int phase, int momentum, float x, float y, float a, float b, int extra) {
        if (closed || videoW == 0) return;
        ByteArrayOutputStream bos = new ByteArrayOutputStream(29);
        DataOutputStream out = new DataOutputStream(bos);
        try {
            out.writeByte(MSG_INPUT);
            out.writeInt(24);
            out.writeByte(kind);
            out.writeByte(button);
            out.writeByte(phase);
            out.writeByte(momentum);
            out.writeFloat(x);
            out.writeFloat(y);
            out.writeFloat(a);
            out.writeFloat(b);
            out.writeInt(extra);
        } catch (IOException ignored) {
        }
        sendQueue.offer(bos.toByteArray());
    }

    private void send(int type, byte[] payload) {
        byte[] b = new byte[5 + payload.length];
        b[0] = (byte) type;
        b[1] = (byte) (payload.length >>> 24);
        b[2] = (byte) (payload.length >>> 16);
        b[3] = (byte) (payload.length >>> 8);
        b[4] = (byte) payload.length;
        System.arraycopy(payload, 0, b, 5, payload.length);
        if (!closed) sendQueue.offer(b);
    }

    private void writeLoop() {
        try {
            while (!closed) {
                byte[] b = sendQueue.take();
                if (b.length == 0) continue;
                // USB: a transfer of whole 512-byte packets has no short packet to end it on the Mac side.
                if (usb && b.length % 512 == 0) b = Arrays.copyOf(b, b.length + 5);
                output.write(b);
                output.flush();
            }
        } catch (IOException | InterruptedException e) {
            close("write: " + e.getMessage());
        }
    }

    private void pingLoop() {
        int n = 0;
        while (!closed) {
            byte[] p = new byte[8];
            long t = System.nanoTime();
            for (int i = 0; i < 8; i++) p[i] = (byte) (t >>> (56 - 8 * i));
            send(MSG_PING, p);
            try {
                Thread.sleep(n++ < 20 ? 100 : 1000);
            } catch (InterruptedException e) {
                return;
            }
            if (n % 2 == 0 && n > 20) reportStats();
        }
    }

    // ---- Receiving ----

    private void readLoop() {
        try {
            DataInputStream in = new DataInputStream(input);
            while (!closed) {
                int type = in.readUnsignedByte();
                int len = in.readInt();
                if (len < 0 || len > (8 << 20)) throw new IOException("bad length " + len);
                if (type == MSG_FRAME) {
                    long captureNs = in.readLong();
                    long sendNs = in.readLong();
                    int flags = in.readUnsignedByte();
                    int n = len - 17;
                    if (frameBuf.length < n) frameBuf = new byte[n + (n >> 1)];
                    in.readFully(frameBuf, 0, n);
                    onFrame(captureNs, sendNs, flags, n, System.nanoTime());
                } else {
                    byte[] payload = new byte[len];
                    in.readFully(payload);
                    onMessage(type, payload);
                }
            }
        } catch (IOException e) {
            close("read: " + e.getMessage());
        }
    }

    private void onMessage(int type, byte[] payload) {
        try {
            if (type == MSG_PONG) {
                long now = System.nanoTime();
                long t0 = 0, mac = 0;
                for (int i = 0; i < 8; i++) t0 = (t0 << 8) | (payload[i] & 0xff);
                for (int i = 8; i < 16; i++) mac = (mac << 8) | (payload[i] & 0xff);
                long rtt = now - t0;
                lastRttNs = rtt;
                if (rtt <= bestRttNs || now - bestRttAt > 15_000_000_000L) {
                    bestRttNs = rtt;
                    bestRttAt = now;
                    clockOffsetNs = mac - (t0 + rtt / 2);
                }
            } else if (type == MSG_CONFIG) {
                JSONObject c = new JSONObject(new String(payload, StandardCharsets.UTF_8));
                synchronized (decoderLock) {
                    if (decoder != null) decoder.release();
                    decoder = null;
                    mime = c.getString("codec");
                    videoW = c.getInt("width");
                    videoH = c.getInt("height");
                    fps = c.optInt("fps", 60);
                    startDecoderLocked();
                }
                final int w = videoW, h = videoH;
                ui.post(() -> listener.onVideoConfig(this, w, h));
            } else if (type == MSG_HELLO_REQUEST) {
                // A restarted Mac host on the same USB link: start over with a fresh hello.
                send(MSG_HELLO, hello.toString().getBytes(StandardCharsets.UTF_8));
            } else if (type == MSG_SHOW) {
                ui.post(() -> listener.onShowRequested(this));
            } else if (type == MSG_STATUS) {
                JSONObject s = new JSONObject(new String(payload, StandardCharsets.UTF_8));
                macStatus = s.optString("message", "");
                ui.post(() -> listener.onMacStatus(this, macStatus));
            }
        } catch (JSONException | RuntimeException e) {
            Log.w(TAG, "message " + type + ": " + e);
        }
    }

    private void onFrame(long captureNs, long sendNs, int flags, int n, long recvNs) {
        statBytes += n + 22;
        if ((flags & 1) != 0) {
            pendingConfig = Arrays.copyOf(frameBuf, n);
            return;
        }
        synchronized (decoderLock) {
            if (decoder == null) return;
            boolean key = (flags & 2) != 0;
            if (!haveKeyframe && !key) {
                requestKeyframe();
                return;
            }
            long pts = captureNs / 1000;
            byte[] data = frameBuf;
            if (key && pendingConfig != null) {
                if (!decoderHasConfig) {
                    decoder.submit(pendingConfig, pendingConfig.length, pts, MediaCodec.BUFFER_FLAG_CODEC_CONFIG);
                    decoderHasConfig = true;
                } else {
                    // Later keyframes carry their parameter sets in-band.
                    data = new byte[pendingConfig.length + n];
                    System.arraycopy(pendingConfig, 0, data, 0, pendingConfig.length);
                    System.arraycopy(frameBuf, 0, data, pendingConfig.length, n);
                    n = data.length;
                }
            }
            int slot = (int) (pts & 255);
            ringPts[slot] = pts;
            ringSend[slot] = sendNs;
            ringRecv[slot] = recvNs;
            if (decoder.submit(data, n, pts, key ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0)) {
                if (key) haveKeyframe = true;
            } else {
                haveKeyframe = false;
                requestKeyframe();
            }
        }
    }

    private void requestKeyframe() {
        long now = System.nanoTime();
        if (now - lastKeyRequestNs < 500_000_000L) return;
        lastKeyRequestNs = now;
        send(MSG_KEYFRAME, new byte[0]);
    }

    @Override
    public void onFrameRendered(long ptsUs, long renderedNs) {
        int slot = (int) (ptsUs & 255);
        long off = clockOffsetNs;
        long captureNs = ptsUs * 1000;
        long total = renderedNs + off - captureNs;
        long mac = -1, net = -1, dec = -1;
        if (ringPts[slot] == ptsUs) {
            mac = ringSend[slot] - captureNs;
            net = ringRecv[slot] + off - ringSend[slot];
            dec = renderedNs - ringRecv[slot];
        }
        synchronized (samples) {
            samples.add(new long[]{total, mac, net, dec});
        }
    }

    @Override
    public void onDecoderError(String message) {
        Log.w(TAG, message);
        haveKeyframe = false;
        requestKeyframe();
    }

    private void reportStats() {
        ArrayList<long[]> s;
        synchronized (samples) {
            s = new ArrayList<>(samples);
            samples.clear();
        }
        long now = System.nanoTime();
        double secs = (now - statSince) / 1e9;
        statSince = now;
        double mbps = statBytes * 8 / secs / 1e6;
        statBytes = 0;
        String decName;
        synchronized (decoderLock) {
            decName = decoder != null ? decoder.name() : "";
        }
        JSONObject j = new JSONObject();
        try {
            j.put("link", usb ? "usb" : "wifi");
            j.put("fps", Math.round(s.size() / secs * 10) / 10.0);
            j.put("mbps", Math.round(mbps * 10) / 10.0);
            j.put("rtt_ms", Math.round(lastRttNs / 1e5) / 10.0);
            j.put("clock_rtt_ms", Math.round(bestRttNs / 1e5) / 10.0);
            j.put("total_p50", pct(s, 0, 50));
            j.put("total_p95", pct(s, 0, 95));
            j.put("mac_p50", pct(s, 1, 50));
            j.put("net_p50", pct(s, 2, 50));
            j.put("net_p95", pct(s, 2, 95));
            j.put("decode_p50", pct(s, 3, 50));
            j.put("decoder", decName);
            // Battery: current in microamps (negative = discharging on most devices), voltage in mV.
            android.content.Context ctx = PadLinkHub.appContext();
            if (ctx != null) {
                android.os.BatteryManager bm = ctx.getSystemService(android.os.BatteryManager.class);
                android.content.Intent b = ctx.registerReceiver(null, new android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED));
                j.put("batt_ua", bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CURRENT_NOW));
                j.put("batt_pct", bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY));
                j.put("batt_mv", b != null ? b.getIntExtra(android.os.BatteryManager.EXTRA_VOLTAGE, 0) : 0);
                j.put("plugged", b != null ? b.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) : 0);
            }
        } catch (JSONException ignored) {
        }
        send(MSG_STATS, j.toString().getBytes(StandardCharsets.UTF_8));
        final String hud = String.format(Locale.US,
                "%s · 延迟 采集→解码 p50 %.1f / p95 %.1f ms\nMac 编码 %.1f · 传输 %.1f (p95 %.1f) · 解码 %.1f ms\n%.0f fps · %.1f Mbps · RTT %.1f ms\n%s",
                usb ? "USB" : "Wi-Fi", j.optDouble("total_p50"), j.optDouble("total_p95"), j.optDouble("mac_p50"), j.optDouble("net_p50"),
                j.optDouble("net_p95"), j.optDouble("decode_p50"), j.optDouble("fps"), mbps, lastRttNs / 1e6, decName);
        ui.post(() -> listener.onHud(this, hud));
    }

    private static double pct(ArrayList<long[]> s, int field, int p) {
        ArrayList<Long> v = new ArrayList<>();
        for (long[] r : s) if (r[field] >= 0 || field == 0) v.add(r[field]);
        if (v.isEmpty()) return -1;
        Collections.sort(v);
        int i = Math.min(v.size() - 1, (int) Math.floor(v.size() * p / 100.0));
        return Math.round(v.get(i) / 1e5) / 10.0;
    }
}
