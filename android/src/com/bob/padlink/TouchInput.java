package com.bob.padlink;

import android.os.Handler;
import android.os.Looper;
import android.view.Choreographer;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;

/**
 * Translates tablet touch, stylus and mouse input into Mac pointer actions, iPad style.
 *
 * Finger:  tap = click, double tap = double click, drag = scroll with momentum,
 *          long press then drag = press-and-drag (select text, move windows, drag files),
 *          long press and release = right click, two-finger tap = right click,
 *          pinch = zoom, three-finger tap = toggle the latency overlay.
 * Stylus:  hover moves the pointer, touch = left button with pressure, side button = right button.
 * Mouse:   passed through (buttons, drag, wheel).
 */
final class TouchInput {
    interface Sink {
        void input(int kind, int button, int phase, int momentum, float x, float y, float a, float b, int extra);
    }

    static final int MOVE = 1, DOWN = 2, UP = 3, DRAG = 4, SCROLL = 5, KEY = 6, MAGNIFY = 7;
    static final int LEFT = 0, RIGHT = 1, MIDDLE = 2;
    // CGScrollPhase / CGMomentumScrollPhase values (gesture phases use the same began/changed/ended bits).
    private static final int PH_NONE = 0, PH_BEGAN = 1, PH_CHANGED = 2, PH_ENDED = 4, PH_CANCELLED = 8;
    private static final int MO_NONE = 0, MO_BEGIN = 1, MO_CONTINUE = 2, MO_END = 3;
    private static final long LONG_PRESS_MS = 450, TWO_TAP_MS = 400, THREE_TAP_MS = 450;

    private enum State { IDLE, PENDING, SCROLLING, HOLD, DRAGGING, TWO_PENDING, TWO_SCROLLING, PINCHING, THREE, WAIT_UP }

    private final View view;
    private final Sink sink;
    private final Runnable onThreeFingerTap;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final float touchSlop;
    private State state = State.IDLE;
    private float downX, downY, lastCx, lastCy, startCx, startCy, startSpan, lastSpan;
    private long downTime, twoDownTime;
    private VelocityTracker velocity;
    private int penButton = LEFT;
    private int mouseButtons;

    // Momentum after a fling, in display fractions per second.
    private float momVx, momVy;
    private long momLastNs;
    private boolean momActive, momStarted;

    private final Runnable longPress = this::onLongPress;

    private void onLongPress() {
        if (state == State.PENDING) {
            state = State.HOLD;
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        }
    }

    private final Choreographer.FrameCallback momentumFrame = new Choreographer.FrameCallback() {
        @Override
        public void doFrame(long frameTimeNanos) {
            if (!momActive) return;
            float dt = Math.min(0.05f, (frameTimeNanos - momLastNs) / 1e9f);
            momLastNs = frameTimeNanos;
            float decay = (float) Math.exp(-dt / 0.45f);
            momVx *= decay;
            momVy *= decay;
            if (Math.hypot(momVx * width(), momVy * height()) < 60) {
                stopMomentum();
                return;
            }
            sink.input(SCROLL, 0, PH_NONE, momStarted ? MO_CONTINUE : MO_BEGIN, nx(lastCx), ny(lastCy), momVx * dt, momVy * dt, 0);
            momStarted = true;
            Choreographer.getInstance().postFrameCallback(this);
        }
    };

    TouchInput(View view, Sink sink, Runnable onThreeFingerTap) {
        this.view = view;
        this.sink = sink;
        this.onThreeFingerTap = onThreeFingerTap;
        this.touchSlop = ViewConfiguration.get(view.getContext()).getScaledTouchSlop();
    }

    private float width() { return Math.max(1, view.getWidth()); }
    private float height() { return Math.max(1, view.getHeight()); }
    private float nx(float x) { return x / width(); }
    private float ny(float y) { return y / height(); }

    /** Input from PadLink's own virtual mouse / keyboard (Mac mouse sharing) must never be sent back to the Mac. */
    static boolean fromBridge(android.view.InputEvent e) {
        android.view.InputDevice d = e.getDevice();
        return d != null && d.getName() != null && d.getName().startsWith("PadLink ");
    }

    boolean onTouch(MotionEvent e) {
        if (fromBridge(e)) return true;
        int tool = e.getToolType(e.getActionIndex());
        if (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER) return onPen(e);
        if (tool == MotionEvent.TOOL_TYPE_MOUSE) return onMouseTouch(e);
        return onFinger(e);
    }

    // ---- Fingers ----

    private boolean onFinger(MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                stopMomentum();
                state = State.PENDING;
                downX = lastCx = e.getX();
                downY = lastCy = e.getY();
                downTime = e.getEventTime();
                if (velocity != null) velocity.recycle();
                velocity = VelocityTracker.obtain();
                velocity.addMovement(e);
                sink.input(MOVE, 0, 0, 0, nx(downX), ny(downY), 0, 0, 0);
                handler.postDelayed(longPress, LONG_PRESS_MS);
                break;

            case MotionEvent.ACTION_POINTER_DOWN:
                if (velocity != null) velocity.addMovement(e);
                if (e.getPointerCount() == 2 && state == State.PENDING) {
                    handler.removeCallbacks(longPress);
                    state = State.TWO_PENDING;
                    twoDownTime = e.getEventTime();
                    startCx = lastCx = centroidX(e);
                    startCy = lastCy = centroidY(e);
                    startSpan = lastSpan = span(e);
                } else if (e.getPointerCount() >= 3 && (state == State.TWO_PENDING || state == State.PENDING)) {
                    handler.removeCallbacks(longPress);
                    state = State.THREE;
                }
                break;

            case MotionEvent.ACTION_MOVE:
                if (velocity != null) velocity.addMovement(e);
                onFingerMove(e);
                break;

            case MotionEvent.ACTION_POINTER_UP:
                if (state == State.TWO_PENDING) {
                    if (e.getEventTime() - twoDownTime < TWO_TAP_MS) click(RIGHT, startCx, startCy);
                    state = State.WAIT_UP;
                } else if (state == State.TWO_SCROLLING) {
                    endScroll(true);
                    state = State.WAIT_UP;
                } else if (state == State.PINCHING) {
                    sink.input(MAGNIFY, 0, PH_ENDED, 0, nx(startCx), ny(startCy), 0, 0, 0);
                    state = State.WAIT_UP;
                }
                break;

            case MotionEvent.ACTION_UP:
                handler.removeCallbacks(longPress);
                switch (state) {
                    case PENDING: click(LEFT, downX, downY); break;
                    case HOLD: click(RIGHT, downX, downY); break;
                    case SCROLLING: endScroll(true); break;
                    case DRAGGING: sink.input(UP, LEFT, 0, 0, nx(e.getX()), ny(e.getY()), 0, 0, 0); break;
                    case THREE: if (e.getEventTime() - downTime < THREE_TAP_MS) onThreeFingerTap.run(); break;
                    default: break;
                }
                state = State.IDLE;
                break;

            case MotionEvent.ACTION_CANCEL:
                handler.removeCallbacks(longPress);
                if (state == State.DRAGGING) sink.input(UP, LEFT, 0, 0, nx(e.getX()), ny(e.getY()), 0, 0, 0);
                if (state == State.SCROLLING || state == State.TWO_SCROLLING) endScroll(false);
                if (state == State.PINCHING) sink.input(MAGNIFY, 0, PH_CANCELLED, 0, nx(startCx), ny(startCy), 0, 0, 0);
                state = State.IDLE;
                break;
        }
        return true;
    }

    private void onFingerMove(MotionEvent e) {
        switch (state) {
            case PENDING:
                if (Math.hypot(e.getX() - downX, e.getY() - downY) > touchSlop) {
                    handler.removeCallbacks(longPress);
                    state = State.SCROLLING;
                    scroll(PH_BEGAN, e.getX(), e.getY());
                }
                break;
            case SCROLLING:
                scroll(PH_CHANGED, e.getX(), e.getY());
                break;
            case HOLD:
                if (Math.hypot(e.getX() - downX, e.getY() - downY) > touchSlop) {
                    state = State.DRAGGING;
                    sink.input(DOWN, LEFT, 0, 0, nx(downX), ny(downY), 1, 0, 0);
                    dragTo(e, LEFT);
                }
                break;
            case DRAGGING:
                dragTo(e, LEFT);
                break;
            case TWO_PENDING:
                if (e.getPointerCount() < 2) break;
                float cx = centroidX(e), cy = centroidY(e), sp = span(e);
                if (Math.abs(sp - startSpan) > Math.max(touchSlop * 2, startSpan * 0.08f)) {
                    state = State.PINCHING;
                    lastSpan = sp;
                    sink.input(MAGNIFY, 0, PH_BEGAN, 0, nx(startCx), ny(startCy), 0, 0, 0);
                } else if (Math.hypot(cx - startCx, cy - startCy) > touchSlop) {
                    state = State.TWO_SCROLLING;
                    sink.input(MOVE, 0, 0, 0, nx(startCx), ny(startCy), 0, 0, 0);
                    scroll(PH_BEGAN, cx, cy);
                }
                break;
            case TWO_SCROLLING:
                if (e.getPointerCount() >= 2) scroll(PH_CHANGED, centroidX(e), centroidY(e));
                break;
            case PINCHING:
                if (e.getPointerCount() >= 2) {
                    float s = span(e);
                    if (lastSpan > 0) sink.input(MAGNIFY, 0, PH_CHANGED, 0, nx(startCx), ny(startCy), s / lastSpan - 1f, 0, 0);
                    lastSpan = s;
                }
                break;
            default:
                break;
        }
    }

    /** Content follows the finger: scroll delta equals finger movement (in display fractions). */
    private void scroll(int phase, float x, float y) {
        sink.input(SCROLL, 0, phase, MO_NONE, nx(x), ny(y), nx(x - lastCx), ny(y - lastCy), 0);
        lastCx = x;
        lastCy = y;
    }

    private void click(int button, float x, float y) {
        sink.input(DOWN, button, 0, 0, nx(x), ny(y), 1, 0, 0);
        sink.input(UP, button, 0, 0, nx(x), ny(y), 0, 0, 0);
    }

    private void dragTo(MotionEvent e, int button) {
        for (int h = 0; h < e.getHistorySize(); h++) {
            sink.input(DRAG, button, 0, 0, nx(e.getHistoricalX(h)), ny(e.getHistoricalY(h)), 1, 0, 0);
        }
        sink.input(DRAG, button, 0, 0, nx(e.getX()), ny(e.getY()), 1, 0, 0);
    }

    private void endScroll(boolean withMomentum) {
        sink.input(SCROLL, 0, withMomentum ? PH_ENDED : PH_CANCELLED, MO_NONE, nx(lastCx), ny(lastCy), 0, 0, 0);
        if (!withMomentum || velocity == null) return;
        velocity.computeCurrentVelocity(1000);
        float vx = velocity.getXVelocity(), vy = velocity.getYVelocity();
        if (Math.hypot(vx, vy) < 300) return;
        momVx = vx / width();
        momVy = vy / height();
        momActive = true;
        momStarted = false;
        momLastNs = System.nanoTime();
        Choreographer.getInstance().postFrameCallback(momentumFrame);
    }

    void stopMomentum() {
        if (!momActive) return;
        momActive = false;
        Choreographer.getInstance().removeFrameCallback(momentumFrame);
        if (momStarted) sink.input(SCROLL, 0, PH_NONE, MO_END, nx(lastCx), ny(lastCy), 0, 0, 0);
    }

    private static float centroidX(MotionEvent e) {
        int n = Math.min(2, e.getPointerCount());
        float s = 0;
        for (int i = 0; i < n; i++) s += e.getX(i);
        return s / n;
    }

    private static float centroidY(MotionEvent e) {
        int n = Math.min(2, e.getPointerCount());
        float s = 0;
        for (int i = 0; i < n; i++) s += e.getY(i);
        return s / n;
    }

    private static float span(MotionEvent e) {
        if (e.getPointerCount() < 2) return 0;
        return (float) Math.hypot(e.getX(0) - e.getX(1), e.getY(0) - e.getY(1));
    }

    // ---- Stylus ----

    private boolean onPen(MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                stopMomentum();
                penButton = (e.getButtonState() & (MotionEvent.BUTTON_STYLUS_PRIMARY | MotionEvent.BUTTON_SECONDARY)) != 0 ? RIGHT : LEFT;
                sink.input(DOWN, penButton, 0, 0, nx(e.getX()), ny(e.getY()), Math.max(0.05f, e.getPressure()), 0, 0);
                break;
            case MotionEvent.ACTION_MOVE:
                for (int h = 0; h < e.getHistorySize(); h++) {
                    sink.input(DRAG, penButton, 0, 0, nx(e.getHistoricalX(h)), ny(e.getHistoricalY(h)), Math.max(0.05f, e.getHistoricalPressure(h)), 0, 0);
                }
                sink.input(DRAG, penButton, 0, 0, nx(e.getX()), ny(e.getY()), Math.max(0.05f, e.getPressure()), 0, 0);
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                sink.input(UP, penButton, 0, 0, nx(e.getX()), ny(e.getY()), 0, 0, 0);
                break;
        }
        return true;
    }

    // ---- Hover (stylus / mouse) ----

    boolean onHover(MotionEvent e) {
        if (fromBridge(e)) return true;
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_HOVER_MOVE || a == MotionEvent.ACTION_HOVER_ENTER) {
            sink.input(MOVE, 0, 0, 0, nx(e.getX()), ny(e.getY()), 0, 0, 0);
        }
        return true;
    }

    // ---- Mouse / touchpad ----

    private boolean onMouseTouch(MotionEvent e) {
        if (e.getActionMasked() == MotionEvent.ACTION_MOVE) {
            int b = mouseButtons;
            int button = (b & MotionEvent.BUTTON_PRIMARY) != 0 ? LEFT : (b & MotionEvent.BUTTON_SECONDARY) != 0 ? RIGHT : (b & MotionEvent.BUTTON_TERTIARY) != 0 ? MIDDLE : -1;
            if (button >= 0) sink.input(DRAG, button, 0, 0, nx(e.getX()), ny(e.getY()), 1, 0, 0);
            else sink.input(MOVE, 0, 0, 0, nx(e.getX()), ny(e.getY()), 0, 0, 0);
        }
        return true;
    }

    boolean onGenericMotion(MotionEvent e) {
        if (fromBridge(e)) return true;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_SCROLL: {
                float v = e.getAxisValue(MotionEvent.AXIS_VSCROLL), h = e.getAxisValue(MotionEvent.AXIS_HSCROLL);
                // One wheel notch scrolls ~40 points on a 1068-point-high display.
                sink.input(SCROLL, 0, PH_NONE, MO_NONE, nx(e.getX()), ny(e.getY()), -h * 0.025f, v * 0.035f, 0);
                return true;
            }
            case MotionEvent.ACTION_BUTTON_PRESS:
            case MotionEvent.ACTION_BUTTON_RELEASE: {
                int ab = e.getActionButton();
                int button = ab == MotionEvent.BUTTON_SECONDARY ? RIGHT : ab == MotionEvent.BUTTON_TERTIARY ? MIDDLE : LEFT;
                boolean press = e.getActionMasked() == MotionEvent.ACTION_BUTTON_PRESS;
                mouseButtons = e.getButtonState();
                sink.input(press ? DOWN : UP, button, 0, 0, nx(e.getX()), ny(e.getY()), press ? 1 : 0, 0, 0);
                return true;
            }
        }
        return false;
    }
}
