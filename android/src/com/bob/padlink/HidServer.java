package com.bob.padlink;

import android.content.ClipData;
import android.content.ClipDescription;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.IBinder;
import android.os.SystemClock;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

/**
 * Runs on the tablet as the adb shell user (not inside the app):
 *   adb shell CLASSPATH=$(pm path com.bob.padlink | cut -d: -f2) app_process / com.bob.padlink.HidServer
 * It creates a virtual USB mouse and keyboard through /dev/uhid, so the Mac's mouse and keyboard drive
 * Android natively (real pointer, every app), and keeps the clipboard in sync both ways.
 * The Mac reaches it through `adb forward tcp:N localabstract:padlink-hid`, so only adb-authorised hosts can.
 *
 * Messages, both directions: [u8 type][u16 big-endian length][payload]
 *   1 mouse report (7 bytes: buttons, dx16 LE, dy16 LE, wheel, pan)   Mac -> tablet
 *   2 keyboard report (8 bytes: modifiers, 0, 6 usages)               Mac -> tablet
 *   3 clipboard text (UTF-8)                                           both
 *   4 hello (UTF-8 "width height")                                     tablet -> Mac
 */
public final class HidServer {
    static final byte[] MOUSE_DESCRIPTOR = {
            0x05, 0x01, 0x09, 0x02, (byte) 0xA1, 0x01, 0x09, 0x01, (byte) 0xA1, 0x00,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, (byte) 0x95, 0x05, 0x75, 0x01, (byte) 0x81, 0x02,
            (byte) 0x95, 0x01, 0x75, 0x03, (byte) 0x81, 0x01,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x01, (byte) 0x80, 0x26, (byte) 0xFF, 0x7F, 0x75, 0x10, (byte) 0x95, 0x02, (byte) 0x81, 0x06,
            0x09, 0x38, 0x15, (byte) 0x81, 0x25, 0x7F, 0x75, 0x08, (byte) 0x95, 0x01, (byte) 0x81, 0x06,
            0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, (byte) 0x81, 0x25, 0x7F, 0x75, 0x08, (byte) 0x95, 0x01, (byte) 0x81, 0x06,
            (byte) 0xC0, (byte) 0xC0,
    };
    static final byte[] KEYBOARD_DESCRIPTOR = {
            0x05, 0x01, 0x09, 0x06, (byte) 0xA1, 0x01, 0x05, 0x07, 0x19, (byte) 0xE0, 0x29, (byte) 0xE7, 0x15, 0x00, 0x25, 0x01,
            0x75, 0x01, (byte) 0x95, 0x08, (byte) 0x81, 0x02, (byte) 0x95, 0x01, 0x75, 0x08, (byte) 0x81, 0x01,
            (byte) 0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, (byte) 0xFF, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2A, (byte) 0xFF, 0x00, (byte) 0x81, 0x00,
            (byte) 0xC0,
    };

    private static final int UHID_DESTROY = 1, UHID_CREATE2 = 11, UHID_INPUT2 = 12;
    private static final int EVENT_SIZE = 4 + 4376;

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("clip-get")) {   // diagnostics
            System.out.println(new Clipboard().getText());
            return;
        }
        if (args.length > 1 && args[0].equals("clip-set")) {
            new Clipboard().setText(args[1]);
            return;
        }
        Uhid mouse = new Uhid("PadLink Mouse", 0x0001, MOUSE_DESCRIPTOR);
        Uhid keyboard = new Uhid("PadLink Keyboard", 0x0002, KEYBOARD_DESCRIPTOR);
        Clipboard clipboard = new Clipboard();
        LocalServerSocket server = new LocalServerSocket("padlink-hid");
        System.out.println("padlink-hid ready");
        try {
            while (true) {
                try (LocalSocket s = server.accept()) {
                    serve(s, mouse, keyboard, clipboard);
                } catch (IOException e) {
                    System.out.println("client: " + e.getMessage());
                }
                keyboard.input(new byte[8]);          // release anything still held
                mouse.input(new byte[7]);
            }
        } finally {
            mouse.close();
            keyboard.close();
        }
    }

    private static void serve(LocalSocket s, Uhid mouse, Uhid keyboard, Clipboard clipboard) throws IOException {
        DataInputStream in = new DataInputStream(s.getInputStream());
        DataOutputStream out = new DataOutputStream(s.getOutputStream());
        Object writeLock = new Object();
        int[] size = displaySize();
        send(out, writeLock, 4, (size[0] + " " + size[1]).getBytes(StandardCharsets.UTF_8));

        // Clipboard -> Mac: only read the content when its description changes (reading it shows a system toast).
        Thread watcher = new Thread(() -> {
            long lastStamp = clipboard.timestamp();
            while (!Thread.currentThread().isInterrupted()) {
                SystemClock.sleep(500);
                long stamp = clipboard.timestamp();
                if (stamp == lastStamp) continue;
                lastStamp = stamp;
                String text = clipboard.getText();
                if (text == null || text.equals(clipboard.lastSet)) continue;
                try {
                    send(out, writeLock, 3, text.getBytes(StandardCharsets.UTF_8));
                } catch (IOException e) {
                    return;
                }
            }
        }, "clipboard");
        watcher.start();
        try {
            while (true) {
                int type = in.readUnsignedByte();
                int len = in.readUnsignedShort();
                byte[] payload = new byte[len];
                in.readFully(payload);
                if (type == 1) mouse.input(payload);
                else if (type == 2) keyboard.input(payload);
                else if (type == 3) clipboard.setText(new String(payload, StandardCharsets.UTF_8));
            }
        } finally {
            watcher.interrupt();
        }
    }

    private static void send(DataOutputStream out, Object lock, int type, byte[] payload) throws IOException {
        synchronized (lock) {
            out.writeByte(type);
            out.writeShort(payload.length);
            out.write(payload);
            out.flush();
        }
    }

    /** Landscape pixel size of the built-in display. */
    private static int[] displaySize() {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"wm", "size"});
            String line = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            String[] wh = line.substring(line.lastIndexOf(':') + 1).trim().split("x");
            int a = Integer.parseInt(wh[0].trim()), b = Integer.parseInt(wh[1].trim());
            return new int[]{Math.max(a, b), Math.min(a, b)};
        } catch (Exception e) {
            return new int[]{1920, 1080};
        }
    }

    /** One virtual HID device. */
    static final class Uhid {
        private final RandomAccessFile dev;

        Uhid(String name, int product, byte[] descriptor) throws IOException {
            dev = new RandomAccessFile("/dev/uhid", "rw");
            byte[] ev = new byte[EVENT_SIZE];
            putInt(ev, 0, UHID_CREATE2);
            byte[] n = name.getBytes(StandardCharsets.UTF_8);
            System.arraycopy(n, 0, ev, 4, Math.min(n.length, 127));
            int o = 4 + 128 + 64 + 64;
            putShort(ev, o, descriptor.length);
            putShort(ev, o + 2, 0x03);                // BUS_USB
            putInt(ev, o + 4, 0x2717);                // vendor
            putInt(ev, o + 8, product);
            putInt(ev, o + 12, 1);                    // version
            putInt(ev, o + 16, 0);                    // country
            System.arraycopy(descriptor, 0, ev, o + 20, descriptor.length);
            dev.write(ev);
        }

        synchronized void input(byte[] report) throws IOException {
            byte[] ev = new byte[EVENT_SIZE];
            putInt(ev, 0, UHID_INPUT2);
            putShort(ev, 4, report.length);
            System.arraycopy(report, 0, ev, 6, report.length);
            dev.write(ev);
        }

        void close() throws IOException {
            byte[] ev = new byte[EVENT_SIZE];
            putInt(ev, 0, UHID_DESTROY);
            dev.write(ev);
            dev.close();
        }

        private static void putInt(byte[] b, int o, int v) {
            b[o] = (byte) v; b[o + 1] = (byte) (v >> 8); b[o + 2] = (byte) (v >> 16); b[o + 3] = (byte) (v >> 24);
        }

        private static void putShort(byte[] b, int o, int v) {
            b[o] = (byte) v; b[o + 1] = (byte) (v >> 8);
        }
    }

    /** System clipboard through the hidden IClipboard service, as the shell package. */
    static final class Clipboard {
        private Object service;
        volatile String lastSet;

        Clipboard() {
            try {
                Class<?> sm = Class.forName("android.os.ServiceManager");
                IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "clipboard");
                service = Class.forName("android.content.IClipboard$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
            } catch (Exception e) {
                System.out.println("clipboard unavailable: " + e);
            }
        }

        long timestamp() {
            Object d = call("getPrimaryClipDescription", null);
            return d instanceof ClipDescription ? ((ClipDescription) d).getTimestamp() : 0;
        }

        String getText() {
            Object c = call("getPrimaryClip", null);
            if (!(c instanceof ClipData) || ((ClipData) c).getItemCount() == 0) return null;
            CharSequence t = ((ClipData) c).getItemAt(0).getText();
            return t == null ? null : t.toString();
        }

        void setText(String text) {
            lastSet = text;
            call("setPrimaryClip", ClipData.newPlainText("PadLink", text));
        }

        /** Calls the first method with this name, filling parameters by type (signatures differ per Android version). */
        private Object call(String name, ClipData clip) {
            if (service == null) return null;
            for (Method m : service.getClass().getMethods()) {
                if (!m.getName().equals(name)) continue;
                Class<?>[] types = m.getParameterTypes();
                Object[] args = new Object[types.length];
                boolean firstString = true;
                for (int i = 0; i < types.length; i++) {
                    if (types[i] == ClipData.class) args[i] = clip;
                    else if (types[i] == String.class) { args[i] = firstString ? "com.android.shell" : null; firstString = false; }
                    else if (types[i] == int.class) args[i] = 0;
                    else if (types[i] == boolean.class) args[i] = false;
                    else args[i] = null;
                }
                try {
                    return m.invoke(service, args);
                } catch (Exception e) {
                    // try the next overload
                }
            }
            return null;
        }
    }
}
