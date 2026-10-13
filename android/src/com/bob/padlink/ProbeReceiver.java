package com.bob.padlink;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;

/**
 * Latency measurement aid: an overlay showing this tablet's wall clock (ms) as a 32-bit barcode,
 * redrawn every frame on top of whatever is on screen (PadLink or the AirPlay receiver).
 * A screenshot then holds both the Mac's clock barcode (through the display path) and this one.
 * adb shell am broadcast -n com.bob.padlink/.ProbeReceiver --ez show true|false
 */
public class ProbeReceiver extends BroadcastReceiver {
    private static View overlay;

    @Override
    public void onReceive(Context context, Intent intent) {
        Context app = context.getApplicationContext();
        WindowManager wm = app.getSystemService(WindowManager.class);
        if (overlay != null) {
            wm.removeView(overlay);
            overlay = null;
        }
        if (!intent.getBooleanExtra("show", true)) return;
        int block = intent.getIntExtra("block", 64);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(32 * block, 2 * block,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.OPAQUE);
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.x = intent.getIntExtra("x", 80);
        lp.y = intent.getIntExtra("y", 1900);
        lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        overlay = new BarcodeView(app, block);
        wm.addView(overlay, lp);
    }

    static final class BarcodeView extends View {
        private final int block;
        private final Paint paint = new Paint();

        BarcodeView(Context c, int block) {
            super(c);
            this.block = block;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int v = (int) System.currentTimeMillis();
            for (int i = 0; i < 32; i++) {
                boolean bit = ((v >>> (31 - i)) & 1) == 1;
                paint.setColor(bit ? Color.WHITE : Color.BLACK);
                canvas.drawRect(i * block, 0, (i + 1) * block, block, paint);
                paint.setColor(bit ? Color.BLACK : Color.WHITE);
                canvas.drawRect(i * block, block, (i + 1) * block, 2 * block, paint);
            }
            postInvalidateOnAnimation();
        }
    }
}
