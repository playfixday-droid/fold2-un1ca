package com.fold2.mon;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.List;
import java.util.regex.Pattern;

/** Управление CPU/GPU через root: чтение состояния, запись по белому списку путей, удержание и применение после загрузки. */
final class Ctl {
    /** Только эти файлы можно менять из интерфейса. */
    static final Pattern PATH = Pattern.compile("^(/sys/devices/system/cpu/cpufreq/policy\\d+/(scaling_governor|scaling_min_freq|scaling_max_freq|[a-z0-9_]+/[a-z0-9_]+)"
            + "|/sys/devices/system/cpu/cpu[1-9]\\d*/online|/sys/devices/system/cpu/cpu\\d+/core_ctl/(enable|min_cpus|max_cpus)"
            + "|/sys/power/cpufreq_(max|min)_limit|/sys/class/kgsl/kgsl-3d0/(max_pwrlevel|min_pwrlevel|devfreq/governor)"
            + "|/proc/sys/kernel/sched_boost|/dev/stune/[a-z-]+/schedtune\\.boost)$");
    static final Pattern VAL = Pattern.compile("^(-?\\d{1,10}|[a-z][a-z0-9_-]{0,31})$");
    static final String SIOP = "/sys/power/cpufreq_max_limit";

    private final Hub hub;
    private final SharedPreferences sp;
    volatile JSONObject cfg = new JSONObject(); // {w:[[путь,значение]...], boot, hold, noSiop, safeT, sec}
    volatile boolean blocked;
    private long at = 0;

    Ctl(Hub h, SharedPreferences sp) {
        hub = h; this.sp = sp;
        try { cfg = new JSONObject(sp.getString("ctl", "{}")); } catch (Exception ignored) { }
        blocked = sp.getBoolean("ctlBlocked", false);
    }

    static JSONObject cfg(Context c) { try { return new JSONObject(c.getSharedPreferences("f2m", Context.MODE_PRIVATE).getString("ctl", "{}")); } catch (Exception e) { return new JSONObject(); } }
    static boolean hold(Context c) { JSONObject j = cfg(c); return j.optBoolean("hold") && j.optJSONArray("w") != null && !c.getSharedPreferences("f2m", Context.MODE_PRIVATE).getBoolean("ctlBlocked", false); }

    /** Запрос из интерфейса: {op: read|write|save|unblock, id, w, cfg}. */
    String handle(String req) {
        JSONObject o = new JSONObject();
        try {
            JSONObject r = new JSONObject(req); String op = r.optString("op");
            o.put("id", r.optInt("id")); o.put("op", op);
            if ("write".equals(op)) o.put("res", write(r.optJSONArray("w")));
            else if ("save".equals(op)) { JSONObject c = r.optJSONObject("cfg"); if (c != null) { cfg = c; sp.edit().putString("ctl", c.toString()).apply(); } }
            else if ("unblock".equals(op)) { blocked = false; sp.edit().putBoolean("ctlBlocked", false).putLong("ctlSkipAt", 0).apply(); }
            o.put("st", read());
        } catch (Exception e) { try { o.put("err", String.valueOf(e.getMessage())); } catch (Exception ignored) { } }
        return o.toString();
    }

    JSONArray write(JSONArray w) {
        JSONArray res = new JSONArray();
        if (w == null) return res;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < w.length(); i++) {
            JSONArray x = w.optJSONArray(i); if (x == null || x.length() < 2) continue;
            String p = x.optString(0), v = x.optString(1).trim();
            if (!PATH.matcher(p).matches() || !VAL.matcher(v).matches()) { res.put(new JSONArray().put(p).put(-1).put("запрещено")); continue; }
            sb.append("f2w ").append(p).append(' ').append(v).append(" 2>/dev/null\n");
        }
        if (sb.length() == 0) return res;
        List<String> out = hub.sh.run(sb.toString().trim(), 20000);
        if (out != null) for (String l : out) {
            String[] a = Hub.sp(l);
            if (a.length >= 3 && a[0].equals("WR")) res.put(new JSONArray().put(a[2]).put(Hub.pl(a[1])).put(Hub.rest(l, 3)));
        }
        return res;
    }

    private static JSONObject obj(JSONObject o, String k) throws Exception { JSONObject r = o.optJSONObject(k); if (r == null) { r = new JSONObject(); o.put(k, r); } return r; }

    JSONObject read() throws Exception {
        JSONObject o = new JSONObject(), pol = new JSONObject(), cc = new JSONObject(), sl = new JSONObject(), gpu = new JSONObject(), kb = new JSONObject();
        JSONArray co = new JSONArray(), req = new JSONArray();
        List<String> l = hub.sh.run("f2ctl 2>/dev/null", 15000);
        if (l != null) for (String s : l) {
            String[] a = Hub.sp(s); if (a.length < 2) continue;
            try {
                switch (a[0]) {
                    case "PF": if (a.length >= 3) obj(pol, a[1]).put(a[2], Hub.rest(s, 3)); break;
                    case "PT": if (a.length >= 3) obj(obj(pol, a[1]), "tun").put(a[2], Hub.rest(s, 3)); break;
                    case "CO": if (a.length >= 4) co.put(new JSONObject().put("i", Hub.pl(a[1])).put("on", "1".equals(a[2])).put("w", "1".equals(a[3]))); break;
                    case "CC": if (a.length >= 3) obj(cc, a[1]).put(a[2], Hub.rest(s, 3)); break;
                    case "SL": sl.put(a[1], Hub.rest(s, 2)); break;
                    case "SR": if (a.length >= 3 && !"name".equals(a[1])) req.put(new JSONObject().put("n", a[1]).put("f", Hub.pl(a[2])).put("s", a.length > 3 ? Hub.pl(a[3]) : 0)); break;
                    case "GK": gpu.put(a[1], Hub.rest(s, 2)); break;
                    case "KB": kb.put(a[1], Hub.rest(s, 2)); break;
                    case "PP": o.put("pp", Hub.rest(s, 1)); break;
                }
            } catch (Exception ignored) { }
        }
        o.put("ok", l != null); o.put("root", hub.sh.root);
        o.put("pol", pol); o.put("co", co); o.put("cc", cc); o.put("sl", sl); o.put("req", req); o.put("gpu", gpu); o.put("kb", kb);
        o.put("cfg", cfg); o.put("blocked", blocked); o.put("skip", sp.getLong("ctlSkipAt", 0));
        return o;
    }

    /** Из цикла сборщика: «удерживать» — повторять запись каждые N секунд; снимать лимит SIOP, пока CPU холоднее порога. */
    void tick() {
        JSONObject c = cfg;
        if (blocked || !c.optBoolean("hold")) return;
        long now = SystemClock.elapsedRealtime();
        if (now - at < Math.max(3, c.optInt("sec", 10)) * 1000L) return;
        at = now;
        JSONArray w = c.optJSONArray("w");
        if (w != null && w.length() > 0) write(w);
        if (c.optBoolean("noSiop")) {
            double t = hub.cpuTmax();
            if (!Double.isNaN(t) && t < c.optDouble("safeT", 75)) write(new JSONArray().put(new JSONArray().put(SIOP).put("-1")));
        }
    }

    /** После загрузки (BootReceiver, в фоне). Если прошлая автоприменённая загрузка оборвалась быстро — не применяем. */
    static void boot(Context ctx) {
        SharedPreferences sp = ctx.getSharedPreferences("f2m", Context.MODE_PRIVATE);
        JSONObject c = cfg(ctx);
        if (!c.optBoolean("boot") || c.optJSONArray("w") == null) return;
        long now = System.currentTimeMillis(), last = sp.getLong("ctlBootAt", 0);
        if (last > 0 && now - last < 3 * 60000L) { sp.edit().putBoolean("ctlBlocked", true).putLong("ctlSkipAt", now).apply(); return; }
        try { Thread.sleep(15000); } catch (InterruptedException ignored) { }
        sp.edit().putLong("ctlBootAt", System.currentTimeMillis()).apply();
        Hub h = Hub.get(ctx);
        h.ctl.blocked = false;
        h.ctl.write(c.optJSONArray("w"));
    }
}
