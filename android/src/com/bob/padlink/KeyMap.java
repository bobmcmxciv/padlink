package com.bob.padlink;

import android.util.SparseIntArray;
import android.view.KeyEvent;

/** Android key codes -> macOS virtual key codes (kVK_*), for a hardware keyboard attached to the tablet. */
final class KeyMap {
    private static final SparseIntArray MAP = new SparseIntArray();

    static {
        int[] letters = {0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06};
        for (int i = 0; i < 26; i++) MAP.put(KeyEvent.KEYCODE_A + i, letters[i]);
        int[] digits = {0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19};
        for (int i = 0; i < 10; i++) MAP.put(KeyEvent.KEYCODE_0 + i, digits[i]);
        int[] fkeys = {0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F};
        for (int i = 0; i < 12; i++) MAP.put(KeyEvent.KEYCODE_F1 + i, fkeys[i]);
        put(KeyEvent.KEYCODE_ENTER, 0x24);
        put(KeyEvent.KEYCODE_NUMPAD_ENTER, 0x4C);
        put(KeyEvent.KEYCODE_TAB, 0x30);
        put(KeyEvent.KEYCODE_SPACE, 0x31);
        put(KeyEvent.KEYCODE_DEL, 0x33);
        put(KeyEvent.KEYCODE_FORWARD_DEL, 0x75);
        put(KeyEvent.KEYCODE_ESCAPE, 0x35);
        put(KeyEvent.KEYCODE_MINUS, 0x1B);
        put(KeyEvent.KEYCODE_EQUALS, 0x18);
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 0x21);
        put(KeyEvent.KEYCODE_RIGHT_BRACKET, 0x1E);
        put(KeyEvent.KEYCODE_BACKSLASH, 0x2A);
        put(KeyEvent.KEYCODE_SEMICOLON, 0x29);
        put(KeyEvent.KEYCODE_APOSTROPHE, 0x27);
        put(KeyEvent.KEYCODE_COMMA, 0x2B);
        put(KeyEvent.KEYCODE_PERIOD, 0x2F);
        put(KeyEvent.KEYCODE_SLASH, 0x2C);
        put(KeyEvent.KEYCODE_GRAVE, 0x32);
        put(KeyEvent.KEYCODE_DPAD_LEFT, 0x7B);
        put(KeyEvent.KEYCODE_DPAD_RIGHT, 0x7C);
        put(KeyEvent.KEYCODE_DPAD_DOWN, 0x7D);
        put(KeyEvent.KEYCODE_DPAD_UP, 0x7E);
        put(KeyEvent.KEYCODE_MOVE_HOME, 0x73);
        put(KeyEvent.KEYCODE_MOVE_END, 0x77);
        put(KeyEvent.KEYCODE_PAGE_UP, 0x74);
        put(KeyEvent.KEYCODE_PAGE_DOWN, 0x79);
        put(KeyEvent.KEYCODE_CAPS_LOCK, 0x39);
        put(KeyEvent.KEYCODE_SHIFT_LEFT, 0x38);
        put(KeyEvent.KEYCODE_SHIFT_RIGHT, 0x3C);
        put(KeyEvent.KEYCODE_CTRL_LEFT, 0x3B);
        put(KeyEvent.KEYCODE_CTRL_RIGHT, 0x3E);
        put(KeyEvent.KEYCODE_ALT_LEFT, 0x3A);
        put(KeyEvent.KEYCODE_ALT_RIGHT, 0x3D);
        put(KeyEvent.KEYCODE_META_LEFT, 0x37);
        put(KeyEvent.KEYCODE_META_RIGHT, 0x36);
    }

    private static void put(int android, int mac) {
        MAP.put(android, mac);
    }

    /** Returns -1 when the key has no Mac equivalent (volume, back, ...), so Android keeps handling it. */
    static int macKeyCode(int androidKeyCode) {
        return MAP.get(androidKeyCode, -1);
    }

    /** CGEventFlags bits for the modifiers held during this event. */
    static int macFlags(KeyEvent e) {
        int f = 0;
        if (e.isCapsLockOn()) f |= 0x10000;
        if (e.isShiftPressed()) f |= 0x20000;
        if (e.isCtrlPressed()) f |= 0x40000;
        if (e.isAltPressed()) f |= 0x80000;
        if (e.isMetaPressed()) f |= 0x100000;
        return f;
    }
}
