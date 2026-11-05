package com.fold2.mon;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** После перезагрузки: настройки CPU/GPU (если включено «применять после перезагрузки») и уведомление/оверлей/удержание. */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())) return;
        final Context ac = c.getApplicationContext();
        final PendingResult pr = goAsync();
        new Thread(() -> {
            try { Ctl.boot(ac); } catch (Throwable ignored) { }
            try { if (MonService.cfg(ac).optBoolean("boot") || (Ctl.cfg(ac).optBoolean("boot") && Ctl.hold(ac))) MonService.sync(ac); } catch (Throwable ignored) { }
            pr.finish();
        }, "f2m-boot").start();
    }
}
