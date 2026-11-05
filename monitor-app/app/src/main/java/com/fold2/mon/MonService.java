package com.fold2.mon;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.WindowManager;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;

/** Показатели в уведомлении и в плавающем окне поверх приложений (удобно в DeX и в играх). */
public class MonService extends Service implements Hub.Listener {
    static final String CH = "mon";
    static final int ID = 7;
    private final Handler h = new Handler(Looper.getMainLooper());
    private Hub hub;
    private NotificationManager nm;
    private WindowManager wm;
    private TextView ov;
    private WindowManager.LayoutParams lp;
    private JSONObject cfg = new JSONObject();
    private long lastN;

    static JSONObject cfg(Context c) {
        try { return new JSONObject(c.getSharedPreferences("f2m", MODE_PRIVATE).getString("svc", "{}")); } catch (Exception e) { return new JSONObject(); }
    }
    static void sync(Context c) {
        JSONObject j = cfg(c);
        Intent i = new Intent(c, MonService.class);
        try { if (j.optBoolean("notif") || j.optBoolean("overlay") || Ctl.hold(c)) c.startForegroundService(i); else c.stopService(i); } catch (Exception ignored) { }
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public void onCreate() {
        super.onCreate();
        nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CH, "Показатели", NotificationManager.IMPORTANCE_LOW));
        wm = getSystemService(WindowManager.class);
        hub = Hub.get(this);
    }

    private int icon() { int r = getResources().getIdentifier("ic_stat", "drawable", getPackageName()); return r != 0 ? r : android.R.drawable.stat_notify_sync; }

    private Notification build(String title, String text) {
        Intent oi = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(this, 0, oi, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CH).setSmallIcon(icon()).setContentTitle(title).setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false).setContentIntent(pi)
                .setCategory(Notification.CATEGORY_SERVICE).build();
    }

    @Override public int onStartCommand(Intent i, int f, int id) {
        cfg = cfg(this);
        boolean hold = Ctl.hold(this), vis = cfg.optBoolean("notif") || cfg.optBoolean("overlay");
        Notification n = build("Fold2 Монитор", cfg.optBoolean("notif") ? "Сбор данных…" : cfg.optBoolean("overlay") ? "Плавающее окно включено" : "Удерживаю настройки CPU/GPU");
        if (Build.VERSION.SDK_INT >= 34) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE); else startForeground(ID, n);
        if (!vis && !hold) { stopSelf(); return START_NOT_STICKY; }
        hub.add(this, vis ? Math.max(500, cfg.optLong("interval", 2000)) : 5000);
        h.post(() -> { removeOverlay(); syncOverlay(); });
        return START_STICKY;
    }

    @Override public void onDestroy() { hub.remove(this); removeOverlay(); super.onDestroy(); }

    @Override public void onSample(String json, JSONObject o) {
        String[] t = Fmt.lines(o, cfg);
        long now = SystemClock.elapsedRealtime();
        if (cfg.optBoolean("notif") && now - lastN >= 1000) { lastN = now; nm.notify(ID, build(t[0], t[1])); }
        if (cfg.optBoolean("overlay")) h.post(() -> {
            if (ov == null) syncOverlay();
            if (ov != null) ov.setText(cfg.optBoolean("ovlLines") ? t[0] + "\n" + t[1] : t[0] + "  ·  " + t[1]);
        });
    }

    private float dp(float v) { return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()); }

    private void syncOverlay() {
        boolean want = cfg.optBoolean("overlay") && Settings.canDrawOverlays(this);
        if (!want) { removeOverlay(); return; }
        if (ov != null) return;
        SharedPreferences sp = getSharedPreferences("f2m", MODE_PRIVATE);
        ov = new TextView(this);
        ov.setTextColor(Color.WHITE);
        ov.setTextSize(TypedValue.COMPLEX_UNIT_SP, (float) cfg.optDouble("ovlSize", 12));
        ov.setTypeface(cfg.optBoolean("ovlMono", true) ? Typeface.MONOSPACE : Typeface.DEFAULT);
        int pad = (int) dp(6); ov.setPadding(pad * 2, pad, pad * 2, pad);
        GradientDrawable bg = new GradientDrawable(); bg.setCornerRadius(dp(10));
        int a = (int) Math.round(255 * Math.max(0, Math.min(1, cfg.optDouble("ovlAlpha", 0.6))));
        bg.setColor(Color.argb(a, 0, 0, 0)); ov.setBackground(bg);
        ov.setText("Fold2 Монитор…");
        lp = new WindowManager.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.x = sp.getInt("ovx", (int) dp(8)); lp.y = sp.getInt("ovy", (int) dp(48));
        ov.setOnTouchListener(new android.view.View.OnTouchListener() {
            float sx, sy; int ox, oy; boolean moved;
            @Override public boolean onTouch(android.view.View v, MotionEvent e) {
                switch (e.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN: sx = e.getRawX(); sy = e.getRawY(); ox = lp.x; oy = lp.y; moved = false; return true;
                    case MotionEvent.ACTION_MOVE:
                        if (Math.abs(e.getRawX() - sx) + Math.abs(e.getRawY() - sy) > dp(6)) moved = true;
                        if (moved) { lp.x = ox + (int) (e.getRawX() - sx); lp.y = oy + (int) (e.getRawY() - sy); try { wm.updateViewLayout(ov, lp); } catch (Exception ignored) { } }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (moved) sp.edit().putInt("ovx", lp.x).putInt("ovy", lp.y).apply();
                        else startActivity(new Intent(MonService.this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP));
                        return true;
                }
                return false;
            }
        });
        try { wm.addView(ov, lp); } catch (Exception e) { ov = null; }
    }

    private void removeOverlay() { if (ov != null) { try { wm.removeView(ov); } catch (Exception ignored) { } ov = null; } }

    /** Короткие строки показателей для уведомления/оверлея. */
    static final class Fmt {
        static double max(JSONArray t, String re) {
            double m = Double.NaN;
            for (int i = 0; i < t.length(); i++) { JSONObject z = t.optJSONObject(i); if (z == null) continue; String n = z.optString("n"); if (n.matches(re)) { double v = z.optDouble("t", Double.NaN); if (!Double.isNaN(v) && (Double.isNaN(m) || v > m)) m = v; } }
            return m;
        }
        static String T(double c, boolean f) { if (Double.isNaN(c)) return "—"; return String.format(Locale.US, "%.0f°", f ? c * 9 / 5 + 32 : c); }
        static String rate(double b) { if (Double.isNaN(b)) return "—"; if (b >= 1e6) return String.format(Locale.US, "%.1fM", b / 1e6); if (b >= 1e3) return String.format(Locale.US, "%.0fK", b / 1e3); return String.format(Locale.US, "%.0f", b); }
        static String[] lines(JSONObject o, JSONObject cfg) {
            JSONArray ms = cfg.optJSONArray("metrics");
            if (ms == null) { ms = new JSONArray(); for (String k : new String[]{"cpu", "cpuT", "gpu", "ram", "bat", "pow"}) ms.put(k); }
            boolean F = "F".equals(cfg.optString("tempUnit"));
            JSONObject cpu = o.optJSONObject("cpu"), gpu = o.optJSONObject("gpu"), mem = o.optJSONObject("mem"), bat = o.optJSONObject("bat"), net = o.optJSONObject("net");
            JSONArray t = o.optJSONArray("temps"); if (t == null) t = new JSONArray();
            StringBuilder a = new StringBuilder(), b = new StringBuilder();
            int n = 0;
            for (int i = 0; i < ms.length(); i++) {
                String k = ms.optString(i), s = null;
                switch (k) {
                    case "cpu": s = "CPU " + (cpu != null && cpu.has("load") ? Math.round(cpu.optDouble("load")) + "%" : "—"); break;
                    case "cpuT": s = "CPU " + T(max(t, "(?i)^(cpu|cpuss).*"), F); break;
                    case "gpu": s = "GPU " + (gpu != null && gpu.has("load") ? Math.round(gpu.optDouble("load")) + "%" : "—"); break;
                    case "gpuT": s = "GPU " + T(gpu != null && gpu.has("t") ? gpu.optDouble("t") : max(t, "(?i).*gpu.*"), F); break;
                    case "npuT": s = "NPU " + T(max(t, "(?i).*(npu|nsp|cdsp|q6|hvx).*"), F); break;
                    case "tmax": s = "max " + T(max(t, "(?i)^(?!.*(ibat|vbat|vph|bcl|lvl|^soc$)).*"), F); break;
                    case "ram": if (mem != null && mem.optLong("total") > 0) s = "RAM " + Math.round(100.0 * (mem.optLong("total") - mem.optLong("avail")) / mem.optLong("total")) + "%"; break;
                    case "bat": if (bat != null && bat.has("lvl")) s = "🔋" + Math.round(bat.optDouble("lvl")) + "%"; break;
                    case "batT": if (bat != null && bat.has("t")) s = "АКБ " + T(bat.optDouble("t"), F); break;
                    case "cur": if (bat != null && bat.has("i")) s = String.format(Locale.US, "%+.2fA", bat.optDouble("i")); break;
                    case "pow": if (bat != null && bat.has("p")) s = String.format(Locale.US, "%+.1fW", bat.optDouble("p")); break;
                    case "net": if (net != null) s = "↓" + rate(net.optDouble("rx", Double.NaN)) + " ↑" + rate(net.optDouble("tx", Double.NaN)); break;
                }
                if (s == null) continue;
                StringBuilder sb = n < (ms.length() + 1) / 2 ? a : b;
                if (sb.length() > 0) sb.append(" · ");
                sb.append(s); n++;
            }
            if (a.length() == 0) a.append("Fold2 Монитор");
            return new String[]{a.toString(), b.toString()};
        }
    }
}
