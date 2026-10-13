package com.bob.padlink;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.util.Log;
import android.view.Surface;

import java.io.IOException;
import java.nio.ByteBuffer;

/** Hardware decoder that renders straight to the SurfaceView, as soon as each frame is decoded. */
final class VideoDecoder {
    interface Listener {
        void onFrameRendered(long ptsUs, long renderedNs);
        void onDecoderError(String message);
    }

    private static final String TAG = "PadLink";
    private final Surface surface;
    private final Listener listener;
    private MediaCodec codec;
    private Thread drainThread;
    private volatile boolean running;
    private String name = "";

    VideoDecoder(Surface surface, Listener listener) {
        this.surface = surface;
        this.listener = listener;
    }

    String name() {
        return name;
    }

    /** Prefer the vendor's dedicated low-latency component, then any hardware decoder. */
    static String pickDecoder(String mime) {
        String best = null;
        int bestScore = -1;
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder()) continue;
            boolean supports = false;
            for (String t : info.getSupportedTypes()) if (t.equalsIgnoreCase(mime)) supports = true;
            if (!supports) continue;
            String n = info.getName();
            if (n.endsWith(".secure")) continue;
            int score = info.isHardwareAccelerated() ? 1 : 0;
            try {
                if (info.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) score += 2;
            } catch (IllegalArgumentException ignored) {
            }
            // Vendor low-latency components: Qualcomm "*.low_latency", MediaTek "*.lowlatency".
            if (n.endsWith(".low_latency") || n.endsWith(".lowlatency")) score += 4;
            if (score > bestScore) {
                bestScore = score;
                best = n;
            }
        }
        return best;
    }

    static boolean hasDecoder(String mime) {
        return pickDecoder(mime) != null;
    }

    synchronized void configure(String mime, int width, int height, int fps) throws IOException {
        release();
        String n = pickDecoder(mime);
        codec = n != null ? MediaCodec.createByCodecName(n) : MediaCodec.createDecoderByType(mime);
        name = codec.getName();
        MediaFormat f = MediaFormat.createVideoFormat(mime, width, height);
        f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        f.setInteger(MediaFormat.KEY_PRIORITY, 0);
        f.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height);
        // Qualcomm: output frames in decode order without reorder buffering.
        f.setInteger("vendor.qti-ext-dec-low-latency.enable", 1);
        f.setInteger("vendor.qti-ext-dec-picture-order.enable", 1);
        codec.configure(f, surface, null, 0);
        codec.start();
        running = true;
        final MediaCodec c = codec;
        drainThread = new Thread(() -> drain(c), "padlink-decode-out");
        drainThread.setPriority(Thread.MAX_PRIORITY);
        drainThread.start();
        Log.i(TAG, "decoder " + name + " " + mime + " " + width + "x" + height);
    }

    /** Called from the network reader thread only. */
    boolean submit(byte[] data, int length, long ptsUs, int flags) {
        MediaCodec c;
        synchronized (this) {
            c = codec;
        }
        if (c == null) return false;
        try {
            int idx = c.dequeueInputBuffer(200_000);
            if (idx < 0) return false;
            ByteBuffer in = c.getInputBuffer(idx);
            if (in == null || in.capacity() < length) {
                c.queueInputBuffer(idx, 0, 0, ptsUs, 0);
                listener.onDecoderError("input buffer too small for " + length + " bytes");
                return false;
            }
            in.clear();
            in.put(data, 0, length);
            c.queueInputBuffer(idx, 0, length, ptsUs, flags);
            return true;
        } catch (IllegalStateException e) {
            listener.onDecoderError("decoder input: " + e);
            return false;
        }
    }

    private void drain(MediaCodec c) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (running) {
            try {
                int idx = c.dequeueOutputBuffer(info, 20_000);
                if (idx >= 0) {
                    boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                    c.releaseOutputBuffer(idx, !config);
                    if (!config) listener.onFrameRendered(info.presentationTimeUs, System.nanoTime());
                }
            } catch (IllegalStateException e) {
                if (running) listener.onDecoderError("decoder output: " + e);
                return;
            }
        }
    }

    synchronized void release() {
        running = false;
        if (drainThread != null) {
            try {
                drainThread.join(300);
            } catch (InterruptedException ignored) {
            }
            drainThread = null;
        }
        if (codec != null) {
            try {
                codec.stop();
            } catch (RuntimeException ignored) {
            }
            codec.release();
            codec = null;
        }
    }
}
