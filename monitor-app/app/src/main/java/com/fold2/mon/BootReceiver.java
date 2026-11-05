package com.fold2.mon;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Автозапуск уведомления/оверлея после перезагрузки (если включено в настройках). */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(i.getAction()) && MonService.cfg(c).optBoolean("boot")) MonService.sync(c);
    }
}
