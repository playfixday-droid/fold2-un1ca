package com.fold2.mon;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.hardware.display.DisplayManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Environment;
import android.os.PowerManager;
import android.os.StatFs;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.view.Display;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/** Сборщик показателей: один фоновый поток, постоянный root-шелл, рассылка JSON подписчикам (экран, уведомление, оверлей). */
public final class Hub {
    public interface Listener { void onSample(String json, JSONObject o); }

    private static Hub inst;
    public static synchronized Hub get(Context c) { if (inst == null) inst = new Hub(c.getApplicationContext()); return inst; }

    final Context ctx;
    final RootShell sh;
    private final SharedPreferences sp;
    final Ctl ctl;
    private final Map<Listener, Long> ls = new ConcurrentHashMap<>();
    private final Object lock = new Object();
    private Thread th;
    volatile boolean wantTop, wantRpc;
    volatile int slowSec = 5, tempEvery = 1;
    volatile String curUnits = "auto";
    volatile boolean curInvert;
    volatile String lastJson;

    private Hub(Context c) {
        ctx = c;
        sp = c.getSharedPreferences("f2m", Context.MODE_PRIVATE);
        ctl = new Ctl(this, sp);
        curUnits = sp.getString("curUnits", "auto");
        curInvert = sp.getBoolean("curInvert", false);
        sh = new RootShell(asset(c, "collect.sh"));
    }

    static String asset(Context c, String n) {
        try (InputStream in = c.getAssets().open(n)) {
            ByteArrayOutputStream bo = new ByteArrayOutputStream(); byte[] b = new byte[8192]; int r;
            while ((r = in.read(b)) > 0) bo.write(b, 0, r);
            return bo.toString("UTF-8");
        } catch (IOException e) { return ""; }
    }

    void setUnits(String u, boolean inv) {
        curUnits = u == null ? "auto" : u; curInvert = inv;
        sp.edit().putString("curUnits", curUnits).putBoolean("curInvert", inv).apply();
    }

    public void add(Listener l, long ms) {
        ls.put(l, Math.max(250, ms));
        synchronized (lock) {
            if (th == null) { th = new Thread(this::loop, "f2m-hub"); th.setDaemon(true); th.start(); }
            lock.notifyAll();
        }
    }
    public void remove(Listener l) { ls.remove(l); }
    public void setInterval(Listener l, long ms) {
        if (ls.containsKey(l)) ls.put(l, Math.max(250, ms));
        synchronized (lock) { lock.notifyAll(); }
    }
    private long interval() { long m = Long.MAX_VALUE; for (long v : ls.values()) m = Math.min(m, v); return m == Long.MAX_VALUE ? 1000 : m; }

    private void loop() {
        while (true) {
            synchronized (lock) { if (ls.isEmpty()) { th = null; return; } }
            long t0 = SystemClock.elapsedRealtime();
            try {
                JSONObject o = sample();
                String s = o.toString().replace("\u2028", "\\u2028").replace("\u2029", "\\u2029");
                lastJson = s;
                for (Listener l : ls.keySet()) { try { l.onSample(s, o); } catch (Throwable e) { Log.w("f2m", "listener", e); } }
            } catch (Throwable e) { Log.w("f2m", "sample", e); }
            try { ctl.tick(); } catch (Throwable e) { Log.w("f2m", "ctl", e); }
            long wait = interval() - (SystemClock.elapsedRealtime() - t0);
            if (wait > 20) synchronized (lock) { try { lock.wait(wait); } catch (InterruptedException ignored) { } }
        }
    }

    // ---------- состояние ----------
    private final Map<String, long[]> prevCpu = new HashMap<>();
    private final Map<String, long[]> prevNet = new HashMap<>();
    private long prevRd = -1, prevWr = -1, prevT = 0, staticAt = -1, slowAt = 0, hrAt = 0, stAt = 0;
    private int tick = 0;
    private float hr = Float.NaN;
    private final Map<Integer, long[]> cpuMax = new TreeMap<>();
    private final Map<Integer, String> cpuRel = new HashMap<>();
    private final Map<String, String> zoneType = new HashMap<>();
    private final Map<String, long[]> dfAvail = new HashMap<>();
    private final Map<String, String> gpuStatic = new HashMap<>();
    private final Map<String, String> sys = new HashMap<>();
    private JSONArray temps = new JSONArray(), sub = null, rpc = null, top = null, storage = null;
    private JSONObject raw = new JSONObject();

    /** Самая горячая зона CPU по последнему замеру (для защиты при снятии лимита SIOP). */
    double cpuTmax() {
        JSONArray t = temps; double m = Double.NaN;
        for (int i = 0; t != null && i < t.length(); i++) { JSONObject z = t.optJSONObject(i); if (z == null) continue;
            if (z.optString("n").matches("(?i)^(cpu|cpuss|apc|silver|gold|prime).*")) { double v = z.optDouble("t", Double.NaN); if (!Double.isNaN(v) && !(m >= v)) m = v; } }
        return m;
    }

    static long pl(String s) {
        if (s == null) return Long.MIN_VALUE;
        s = s.trim(); int i = 0, n = s.length();
        if (i < n && (s.charAt(i) == '-' || s.charAt(i) == '+')) i++;
        int j = i; while (j < n && Character.isDigit(s.charAt(j))) j++;
        if (j == i) return Long.MIN_VALUE;
        try { return Long.parseLong(s.substring(0, j)); } catch (NumberFormatException e) { return Long.MIN_VALUE; }
    }
    static String[] sp(String s) { return s.trim().split("\\s+"); }
    static String rest(String s, int k) { // строка без первых k полей
        String t = s.trim(); for (int i = 0; i < k; i++) { int p = t.indexOf(' '); if (p < 0) return ""; t = t.substring(p + 1).trim(); } return t;
    }
    static Double normT(long v) {
        if (v == Long.MIN_VALUE) return null;
        double t = Math.abs(v) >= 1000 ? v / 1000.0 : Math.abs(v) > 200 ? v / 10.0 : v;
        return (t < -40 || t > 200) ? null : Math.round(t * 10) / 10.0;
    }
    static void put(JSONObject o, String k, double v) { try { if (!Double.isNaN(v) && !Double.isInfinite(v)) o.put(k, Math.round(v * 1000) / 1000.0); } catch (Exception ignored) { } }
    static void put(JSONObject o, String k, Object v) { try { if (v != null) o.put(k, v); } catch (Exception ignored) { } }

    JSONObject sample() throws Exception {
        long now = SystemClock.elapsedRealtime();
        JSONObject o = new JSONObject();
        o.put("v", 1); o.put("t", System.currentTimeMillis());
        if (staticAt < 0 || now - staticAt > 180000) { List<String> s = sh.run("f2s 2>/dev/null", 45000); if (s != null) { parseStatic(s); staticAt = now; } }
        boolean tz = tick++ % Math.max(1, tempEvery) == 0;
        List<String> f = sh.run("f2f " + (tz ? 1 : 0) + " 2>/dev/null", 10000);
        o.put("root", sh.root);
        double dt = prevT == 0 ? 0 : (now - prevT) / 1000.0; prevT = now;
        o.put("dt", dt);
        Map<String, String> P = new LinkedHashMap<>();
        if (f != null) parseFast(f, o, dt, tz, P); else o.put("err", "shell");
        if (now - slowAt >= slowSec * 1000L) { slowAt = now; slow(P); }
        put(o, "sub", sub);
        if (wantRpc) put(o, "rpc", rpc);
        if (wantTop) put(o, "top", top);
        battery(o, P);
        if (storage == null || now - stAt > 10000) { storage = storage(); stAt = now; }
        o.put("st", storage);
        sys(o, now);
        return o;
    }

    private void parseStatic(List<String> L) {
        for (String l : L) {
            String[] a = sp(l); if (a.length < 1) continue;
            switch (a[0]) {
                case "K": sys.put("kern", rest(l, 1)); break;
                case "SE": sys.put("se", rest(l, 1)); break;
                case "FW": sys.put("fw", rest(l, 1)); break;
                case "OU": sys.put("oneui", rest(l, 1)); break;
                case "HW": sys.put("hw", rest(l, 1)); break;
                case "CS": if (a.length >= 4) { int n = (int) pl(a[1]); cpuMax.put(n, new long[]{pl(a[2]), pl(a[3])}); cpuRel.put(n, a.length > 4 ? rest(l, 4) : a[1]); } break;
                case "ZT": if (a.length >= 3) zoneType.put(a[1], a[2]); break;
                case "DA": if (a.length >= 3) { long mn = Long.MAX_VALUE, mx = Long.MIN_VALUE; for (int i = 2; i < a.length; i++) { long v = pl(a[i]); if (v == Long.MIN_VALUE) continue; mn = Math.min(mn, v); mx = Math.max(mx, v); } if (mx > Long.MIN_VALUE) dfAvail.put(a[1], new long[]{mn, mx}); } break;
                case "GS": if (a.length >= 3) gpuStatic.put(a[1], rest(l, 2)); break;
            }
        }
    }

    private void parseFast(List<String> L, JSONObject o, double dt, boolean tz, Map<String, String> P) throws Exception {
        Map<String, Double> load = new HashMap<>();
        JSONArray cores = new JSONArray();
        JSONArray nt = new JSONArray();
        JSONObject gpu = new JSONObject(), mem = new JSONObject(), net = new JSONObject(), cpu = new JSONObject();
        JSONArray df = new JSONArray(), ifs = new JSONArray();
        String iso = "";
        long rd = 0, wr = 0; boolean io = false;
        double rxs = 0, txs = 0;
        long gb = -1, gt = -1;
        for (String l : L) {
            if (l.length() < 2) continue;
            int sp0 = l.indexOf(' '); if (sp0 < 0) continue;
            String tag = l.substring(0, sp0);
            switch (tag) {
                case "S": {
                    String[] a = sp(l); if (a.length < 9) break;
                    long tot = 0; for (int i = 2; i < Math.min(a.length, 10); i++) { long v = pl(a[i]); if (v > 0) tot += v; }
                    long idle = Math.max(0, pl(a[5])) + Math.max(0, pl(a[6]));
                    long[] pv = prevCpu.put(a[1], new long[]{tot, idle});
                    if (pv != null && tot > pv[0]) load.put(a[1], 100.0 * (1 - (double) (idle - pv[1]) / (tot - pv[0])));
                    break;
                }
                case "C": {
                    String[] a = sp(l); if (a.length < 7) break;
                    int n = (int) pl(a[1]);
                    JSONObject c = new JSONObject();
                    c.put("i", n); c.put("on", pl(a[2]) == 1 ? 1 : 0);
                    long cur = pl(a[3]);
                    if (cur > 0) put(c, "f", cur / 1000.0);
                    if (pl(a[4]) > 0) put(c, "lmin", pl(a[4]) / 1000.0);
                    if (pl(a[5]) > 0) put(c, "lmax", pl(a[5]) / 1000.0);
                    if (!"-".equals(a[6])) c.put("gov", a[6]);
                    long[] mm = cpuMax.get(n);
                    if (mm != null) { put(c, "fmin", mm[0] / 1000.0); put(c, "fmax", mm[1] / 1000.0); }
                    String rel = cpuRel.get(n); if (rel != null) c.put("cl", (int) pl(rel));
                    Double ld = load.get("cpu" + n); if (ld != null) put(c, "load", Math.max(0, Math.min(100, ld)));
                    cores.put(c);
                    break;
                }
                case "ISO": iso = rest(l, 1); break;
                case "Z": {
                    String[] a = sp(l); if (a.length < 3) break;
                    Double t = normT(pl(a[2])); if (t == null) break;
                    String ty = zoneType.get(a[1]);
                    JSONObject z = new JSONObject(); z.put("n", ty != null ? ty : "zone" + a[1]); z.put("t", t); nt.put(z);
                    break;
                }
                case "G": {
                    String[] a = sp(l); if (a.length < 3) break;
                    switch (a[1]) {
                        case "gpu_busy_percentage": { long v = pl(a[2]); if (v >= 0) put(gpu, "load", Math.min(100, v)); break; }
                        case "gpubusy": if (a.length >= 4) { gb = pl(a[2]); gt = pl(a[3]); } break;
                        case "gpuclk": { long v = pl(a[2]); if (v > 0) put(gpu, "f", v / 1e6); break; }
                        case "devfreq/cur_freq": { long v = pl(a[2]); if (v > 0 && !gpu.has("f")) put(gpu, "f", v / 1e6); break; }
                        case "temp": { Double t = normT(pl(a[2])); if (t != null) put(gpu, "t", t); break; }
                    }
                    break;
                }
                case "D": {
                    String[] a = sp(l); if (a.length < 3) break;
                    JSONObject d = new JSONObject(); d.put("n", a[1]);
                    long c = pl(a[2]), mn = a.length > 3 ? pl(a[3]) : Long.MIN_VALUE, mx = a.length > 4 ? pl(a[4]) : Long.MIN_VALUE;
                    if (c != Long.MIN_VALUE) d.put("c", c);
                    if (mn != Long.MIN_VALUE) d.put("mn", mn);
                    if (mx != Long.MIN_VALUE) d.put("mx", mx);
                    long[] av = dfAvail.get(a[1]);
                    if (av != null) { d.put("ai", av[0]); d.put("am", av[1]); if (c != Long.MIN_VALUE && av[1] > av[0]) put(d, "pct", Math.max(0, Math.min(100, 100.0 * (c - av[0]) / (av[1] - av[0])))); }
                    df.put(d);
                    break;
                }
                case "M": {
                    String[] a = sp(l); if (a.length < 3) break;
                    String k = a[1].replace(":", ""); long v = pl(a[2]); if (v < 0) break;
                    String key = k.equals("MemTotal") ? "total" : k.equals("MemFree") ? "free" : k.equals("MemAvailable") ? "avail" : k.equals("Buffers") ? "buf" : k.equals("Cached") ? "cached" : k.equals("SwapTotal") ? "swapT" : k.equals("SwapFree") ? "swapF" : k.equals("Shmem") ? "shmem" : null;
                    if (key != null) mem.put(key, v * 1024);
                    break;
                }
                case "ZR": { String[] a = sp(l); if (a.length >= 4) { mem.put("zo", Math.max(0, pl(a[1]))); mem.put("zc", Math.max(0, pl(a[2]))); mem.put("zu", Math.max(0, pl(a[3]))); } break; }
                case "IO": { String[] a = sp(l); if (a.length >= 4) { long r = pl(a[2]), w = pl(a[3]); if (r >= 0) rd += r; if (w >= 0) wr += w; io = true; } break; }
                case "N": {
                    String s = l.substring(2); int c = s.indexOf(':'); if (c < 0) break;
                    String nm = s.substring(0, c).trim(); String[] a = sp(s.substring(c + 1)); if (a.length < 9) break;
                    long rx = pl(a[0]), tx = pl(a[8]);
                    if (nm.equals("lo") || nm.matches("(dummy|ifb|sit|ip6tnl|ip_vti|ip6_vti|tunl|gre|gretap|erspan|ip6gre|rmnet_ipa|bond|teql).*")) break;
                    long[] pv = prevNet.put(nm, new long[]{rx, tx});
                    if (rx <= 0 && tx <= 0) break;
                    JSONObject ifo = new JSONObject(); ifo.put("n", nm); ifo.put("rxT", rx); ifo.put("txT", tx);
                    if (pv != null && dt > 0) {
                        double r = Math.max(0, (rx - pv[0]) / dt), t = Math.max(0, (tx - pv[1]) / dt);
                        put(ifo, "rx", r); put(ifo, "tx", t);
                        if (nm.matches("(wlan|rmnet_data|eth|rndis|usb|ccmni|seth).*")) { rxs += r; txs += t; }
                    }
                    ifs.put(ifo);
                    break;
                }
                case "U": { String[] a = sp(l); if (a.length >= 2) try { sys.put("up", a[1]); } catch (Exception ignored) { } break; }
                case "L": sys.put("la", rest(l, 1)); break;
                case "PR": cpu.put("run", pl(rest(l, 1))); break;
                case "P": { String[] a = sp(l); if (a.length >= 3) P.put(a[1] + "." + a[2], a.length > 3 ? rest(l, 3) : ""); break; }
            }
        }
        if (!gpu.has("load") && gb >= 0 && gt > 0) put(gpu, "load", Math.min(100, 100.0 * gb / gt));
        String m = gpuStatic.get("gpu_model"); if (m != null) gpu.put("model", m);
        long mg = pl(gpuStatic.get("max_gpuclk")); if (mg > 0) put(gpu, "fmax", mg / 1e6);
        else { long mm = pl(gpuStatic.get("max_clock_mhz")); if (mm > 0) gpu.put("fmax", mm); }
        Double tl = load.get("cpu"); if (tl != null) put(cpu, "load", Math.max(0, Math.min(100, tl)));
        cpu.put("cores", cores); cpu.put("iso", iso);
        o.put("cpu", cpu);
        if (tz) temps = nt;
        o.put("temps", temps);
        o.put("gpu", gpu); o.put("df", df); o.put("mem", mem);
        if (io) {
            JSONObject d = new JSONObject();
            if (prevRd >= 0 && dt > 0) { put(d, "rd", Math.max(0, (rd - prevRd) * 512.0 / dt)); put(d, "wr", Math.max(0, (wr - prevWr) * 512.0 / dt)); }
            d.put("rdT", rd * 512); d.put("wrT", wr * 512);
            prevRd = rd; prevWr = wr; o.put("disk", d);
        }
        put(net, "rx", rxs); put(net, "tx", txs); net.put("ifs", ifs); o.put("net", net);
    }

    private void slow(Map<String, String> P) {
        List<String> s = sh.run("f2sub 2>/dev/null", 5000);
        if (s != null) { JSONArray a = new JSONArray(); for (String l : s) { String[] x = sp(l); if (x.length >= 3 && x[0].equals("SB")) { JSONObject j = new JSONObject(); put(j, "n", x[1]); put(j, "s", x[2]); a.put(j); } } sub = a; }
        if (wantTop) {
            List<String> t = sh.run("f2top 8 2>/dev/null", 8000);
            if (t != null) { JSONArray a = new JSONArray(); for (String l : t) { String[] x = sp(l); if (x.length < 5 || !x[0].equals("TP") || pl(x[1]) <= 0) continue; JSONObject j = new JSONObject(); put(j, "p", pl(x[1])); try { put(j, "c", Double.parseDouble(x[2])); } catch (Exception e) { continue; } put(j, "m", x[3]); put(j, "n", rest(l, 4)); a.put(j); } top = a; }
        }
        if (wantRpc) {
            List<String> r = sh.run("f2rpc 2>/dev/null", 8000);
            if (r != null) {
                LinkedHashSet<String> pids = new LinkedHashSet<>();
                for (String l : r) { String[] x = sp(l); if (x.length >= 2 && x[0].equals("RP") && pl(x[1]) > 0) pids.add(x[1]); }
                JSONArray a = new JSONArray();
                if (!pids.isEmpty()) {
                    List<String> c = sh.run("f2comm " + String.join(" ", pids) + " 2>/dev/null", 5000);
                    if (c != null) for (String l : c) { String[] x = sp(l); if (x.length >= 3 && x[0].equals("RC")) { JSONObject j = new JSONObject(); put(j, "p", pl(x[1])); put(j, "n", rest(l, 2)); a.put(j); } }
                }
                rpc = a;
            }
        }
        JSONObject rw = new JSONObject(); for (Map.Entry<String, String> e : P.entrySet()) put(rw, e.getKey(), e.getValue()); raw = rw;
    }

    private double curA(long v) {
        if (v == Long.MIN_VALUE) return Double.NaN;
        switch (curUnits) {
            case "ua": return v / 1e6;
            case "ma": return v / 1e3;
            default: return Math.abs(v) >= 20000 ? v / 1e6 : v / 1e3;
        }
    }
    static double volt(long v) { if (v == Long.MIN_VALUE || v <= 0) return Double.NaN; return v > 100000 ? v / 1e6 : v > 100 ? v / 1e3 : v; }
    static double mah(long v) { if (v == Long.MIN_VALUE || v <= 0) return Double.NaN; return v > 100000 ? v / 1000.0 : v; }

    private void battery(JSONObject o, Map<String, String> P) throws Exception {
        JSONObject b = new JSONObject();
        Intent bi = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        BatteryManager bm = ctx.getSystemService(BatteryManager.class);
        double v = Double.NaN;
        if (bi != null) {
            int lv = bi.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), sc = bi.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            if (lv >= 0 && sc > 0) put(b, "lvl", 100.0 * lv / sc);
            int st = bi.getIntExtra(BatteryManager.EXTRA_STATUS, 1);
            b.put("st", st == 2 ? "charging" : st == 3 ? "discharging" : st == 4 ? "not_charging" : st == 5 ? "full" : "unknown");
            int pg = bi.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
            b.put("plug", pg == 1 ? "ac" : pg == 2 ? "usb" : pg == 4 ? "wireless" : pg == 8 ? "dock" : "none");
            int hl = bi.getIntExtra(BatteryManager.EXTRA_HEALTH, 1);
            b.put("hl", hl == 2 ? "good" : hl == 3 ? "overheat" : hl == 4 ? "dead" : hl == 5 ? "overvoltage" : hl == 6 ? "failure" : hl == 7 ? "cold" : "unknown");
            int t = bi.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE); if (t != Integer.MIN_VALUE) put(b, "t", t / 10.0);
            int mv = bi.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1); if (mv > 0) { v = mv > 100 ? mv / 1000.0 : mv; put(b, "v", v); }
            put(b, "tech", bi.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY));
        }
        double i = Double.NaN;
        String ua = P.get("battery.batt_current_ua_now");
        if (ua != null && pl(ua) != Long.MIN_VALUE) i = pl(ua) / 1e6;
        else if (P.containsKey("battery.current_now")) i = curA(pl(P.get("battery.current_now")));
        else if (bm != null) { int c = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW); if (c != Integer.MIN_VALUE && c != 0) i = curA(c); }
        if (!Double.isNaN(i) && curInvert) i = -i;
        put(b, "i", i);
        if (!Double.isNaN(i) && !Double.isNaN(v)) put(b, "p", i * v);
        String ia = P.get("battery.batt_current_ua_avg");
        double iav = ia != null ? pl(ia) / 1e6 : P.containsKey("battery.current_avg") ? curA(pl(P.get("battery.current_avg"))) : Double.NaN;
        if (!Double.isNaN(iav) && curInvert) iav = -iav;
        put(b, "ia", iav);
        double cc = mah(pl(P.get("battery.charge_counter")));
        if (Double.isNaN(cc) && bm != null) { int c = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER); if (c > 0) cc = mah(c); }
        put(b, "cc", cc);
        double cf = mah(pl(P.get("battery.charge_full"))), cd = mah(pl(P.get("battery.charge_full_design")));
        put(b, "cf", cf); put(b, "cd", cd);
        if (!Double.isNaN(cf) && !Double.isNaN(cd) && cd > 0) put(b, "hp", 100.0 * cf / cd);
        else { long a = pl(P.get("battery.fg_asoc")); if (a > 0 && a <= 120) put(b, "hp", a); }
        long cy = pl(P.get("battery.cycle_count")); if (cy < 0) cy = pl(P.get("battery.battery_cycle")); if (cy >= 0) b.put("cyc", cy);
        long ttf = -1;
        if (bm != null && Build.VERSION.SDK_INT >= 28) { long r = bm.computeChargeTimeRemaining(); if (r > 0) ttf = r / 1000; }
        if (ttf < 0) { long r = pl(P.get("battery.time_to_full_now")); if (r > 0) ttf = r; }
        if (ttf > 0) b.put("ttf", ttf);
        put(b, "fast", P.get("battery.hv_charger_status"));
        put(b, "ctype", P.get("battery.charge_type"));
        put(b, "src", P.get("battery.batt_charging_source"));
        // вход зарядника: первый online-источник кроме battery
        for (String dev : new String[]{"usb", "ac", "wireless", "pd", "otg", "dc", "main"}) {
            String on = P.get(dev + ".online");
            if (on == null || pl(on) != 1) continue;
            JSONObject in = new JSONObject(); in.put("n", dev);
            double iv = volt(pl(P.get(dev + ".voltage_now")));
            double ic = P.containsKey(dev + ".current_now") ? Math.abs(curA(pl(P.get(dev + ".current_now")))) : Double.NaN;
            double im = P.containsKey(dev + ".current_max") ? Math.abs(curA(pl(P.get(dev + ".current_max")))) : P.containsKey(dev + ".input_current_limit") ? Math.abs(curA(pl(P.get(dev + ".input_current_limit")))) : Double.NaN;
            put(in, "v", iv); put(in, "i", ic); put(in, "imax", im);
            if (!Double.isNaN(iv) && !Double.isNaN(ic)) put(in, "p", iv * ic);
            put(in, "type", P.containsKey(dev + ".real_type") ? P.get(dev + ".real_type") : P.get(dev + ".usb_type"));
            b.put("in", in);
            break;
        }
        b.put("raw", raw);
        o.put("bat", b);
    }

    private JSONArray storage() {
        JSONArray a = new JSONArray();
        String[][] ps = {{"/data", Environment.getDataDirectory().getPath()}, {"/system", "/system"}};
        for (String[] p : ps) {
            try {
                StatFs s = new StatFs(p[1]);
                JSONObject j = new JSONObject(); j.put("n", p[0]); j.put("total", s.getTotalBytes()); j.put("free", s.getAvailableBytes()); a.put(j);
            } catch (Exception ignored) { }
        }
        return a;
    }

    private void sys(JSONObject o, long now) throws Exception {
        JSONObject s = new JSONObject();
        String up = sys.get("up"); if (up != null) try { put(s, "up", Double.parseDouble(up)); } catch (Exception ignored) { }
        String la = sys.get("la");
        if (la != null) { String[] a = sp(la); JSONArray j = new JSONArray(); for (int i = 0; i < Math.min(3, a.length); i++) try { j.put(Double.parseDouble(a[i])); } catch (Exception ignored) { } s.put("la", j); if (a.length > 3) s.put("tasks", a[3]); }
        for (String k : new String[]{"kern", "se", "fw", "oneui", "hw"}) put(s, k, sys.get(k));
        s.put("and", Build.VERSION.RELEASE); s.put("sdk", Build.VERSION.SDK_INT);
        s.put("model", Build.MODEL); s.put("dev", Build.DEVICE); s.put("man", Build.MANUFACTURER);
        if (Build.VERSION.SDK_INT >= 31) put(s, "soc", Build.SOC_MODEL);
        PowerManager pm = ctx.getSystemService(PowerManager.class);
        if (pm != null) {
            s.put("ts", pm.getCurrentThermalStatus());
            if (now - hrAt >= 3000) { hrAt = now; try { hr = pm.getThermalHeadroom(10); } catch (Throwable ignored) { } }
            if (!Float.isNaN(hr)) put(s, "hr", hr);
            s.put("ps", pm.isPowerSaveMode());
        }
        try {
            DisplayManager dm = ctx.getSystemService(DisplayManager.class);
            Display d = dm != null ? dm.getDisplay(Display.DEFAULT_DISPLAY) : null;
            if (d != null) put(s, "hz", d.getRefreshRate());
        } catch (Throwable ignored) { }
        try { s.put("br", Settings.System.getInt(ctx.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS)); } catch (Throwable ignored) { }
        o.put("sys", s);
    }

    /** Постоянный шелл: su (или sh без root), функции из collect.sh, маркер конца ответа, таймаут с перезапуском. */
    static final class RootShell {
        private static final String EOF = "\u0000EOF";
        private Process p; private OutputStream os; private LinkedBlockingQueue<String> q;
        private final String init; private int seq;
        volatile boolean root, retry;
        RootShell(String init) { this.init = init; }

        private boolean start(String exe) {
            try {
                final Process np = new ProcessBuilder(exe).start();
                final LinkedBlockingQueue<String> nq = new LinkedBlockingQueue<>();
                Thread r = new Thread(() -> {
                    try (BufferedReader br = new BufferedReader(new InputStreamReader(np.getInputStream(), StandardCharsets.UTF_8))) {
                        String l; while ((l = br.readLine()) != null) nq.offer(l);
                    } catch (IOException ignored) { }
                    nq.offer(EOF);
                }, "f2m-sh");
                r.setDaemon(true); r.start();
                Thread e = new Thread(() -> { try (InputStream es = np.getErrorStream()) { byte[] b = new byte[4096]; while (es.read(b) >= 0) { } } catch (IOException ignored) { } }, "f2m-sh-err");
                e.setDaemon(true); e.start();
                p = np; os = np.getOutputStream(); q = nq;
                os.write((init + "\n").getBytes(StandardCharsets.UTF_8)); os.flush();
                List<String> id = raw("id -u", exe.equals("su") ? 40000 : 5000);
                if (id == null || id.isEmpty()) { kill(); return false; }
                root = id.get(id.size() - 1).trim().equals("0");
                if (exe.equals("su") && !root) { kill(); return false; }
                return true;
            } catch (IOException ex) { kill(); return false; }
        }
        private void kill() { if (p != null) try { p.destroy(); } catch (Throwable ignored) { } p = null; os = null; q = null; }
        private boolean ensure() {
            if (retry) { retry = false; kill(); }
            if (p != null && p.isAlive()) return true;
            kill(); root = false;
            return start("su") || start("sh");
        }
        synchronized List<String> run(String cmd, long to) {
            if (!ensure()) return null;
            List<String> r = raw(cmd, to);
            if (r == null) kill();
            return r;
        }
        private List<String> raw(String cmd, long to) {
            try {
                String mark = "__F2M_" + (++seq) + "__";
                os.write((cmd + "\necho " + mark + "\n").getBytes(StandardCharsets.UTF_8)); os.flush();
                ArrayList<String> out = new ArrayList<>();
                long dl = SystemClock.elapsedRealtime() + to;
                while (true) {
                    long rem = dl - SystemClock.elapsedRealtime(); if (rem <= 0) return null;
                    String l = q.poll(rem, TimeUnit.MILLISECONDS);
                    if (l == null || l == EOF) return null;
                    if (l.endsWith(mark)) { if (l.length() > mark.length()) out.add(l.substring(0, l.length() - mark.length())); return out; }
                    out.add(l);
                }
            } catch (Exception e) { return null; }
        }
    }
}
