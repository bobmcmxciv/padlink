package com.bob.padlink;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Puts the tablet back on standby after a reboot (needs HyperOS "自启动" allowed for this app). */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) PadLinkService.start(context);
    }
}
