package com.bob.padlink;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;

/**
 * Keeps the tablet reachable in the background ("standby"): the Mac can pick it from its menu bar
 * and the full-screen display comes up by itself, like an AirPlay receiver.
 */
public class PadLinkService extends Service {
    private static final String CHANNEL = "padlink";
    private static final String ACTION_STOP = "com.bob.padlink.STOP";
    private static final int ID = 1;

    static void start(Context c) {
        c.startForegroundService(new Intent(c, PadLinkService.class));
    }

    /** Re-post the notification with the current state. */
    static void refresh(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        nm.notify(ID, build(c));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Mac 副屏待命", NotificationManager.IMPORTANCE_LOW));
        startForeground(ID, build(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        PadLinkHub.get(this).start();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            PadLinkHub.get(this).stop();
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        PadLinkHub.get(this).stop();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private static Notification build(Context c) {
        Session s = PadLinkHub.get(c).session();
        String text;
        if (s != null && !s.isClosed()) {
            text = "已作为 Mac 副屏连接（" + (s.usb ? "USB" : "Wi-Fi") + "）";
        } else {
            String ip = PadLinkHub.wifiAddress();
            text = "待命中，可在 Mac 菜单栏 PadLink 中选择本机" + (ip != null ? "（" + ip + "）" : "");
        }
        PendingIntent open = PendingIntent.getActivity(c, 0, new Intent(c, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(c, 1, new Intent(c, PadLinkService.class).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(c, CHANNEL)
                .setSmallIcon(R.drawable.ic_launcher_fg)
                .setContentTitle("Mac 副屏")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(open)
                .addAction(new Notification.Action.Builder(null, "停止待命", stop).build())
                .build();
    }
}
