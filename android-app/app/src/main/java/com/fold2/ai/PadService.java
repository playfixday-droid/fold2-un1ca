package com.fold2.ai;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ServiceInfo;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.Icon;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.Display;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Экранный джойстик: окно поверх всего на экране телефона (дисплей 0), игра - на мониторе DeX.
 * Окно не берёт фокус (FLAG_NOT_FOCUSABLE): касания пульта не уводят клавиатуру от игры, а нажатия идут
 * через f2pad (uinput, root) - виртуальные клавиатура, мышь и геймпад Xbox 360. В режиме настройки окно
 * фокусируемое (ввод имён сценариев). Не Activity: у приложения без фокусного окна клавиши ждали бы его (ANR).
 */
public class PadService extends Service {
    static final int PORT = 8095;
    static volatile boolean running;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService pool = Executors.newCachedThreadPool();
    private WindowManager wm;
    private WebView web;
    private WindowManager.LayoutParams lp;
    private String token, script;
    private DatagramSocket sock;
    private Vibrator vib;

    @Override
    public IBinder onBind(Intent i) {
        return null;
    }

    @Override
    public int onStartCommand(Intent it, int flags, int startId) {
        if (it != null && "stop".equals(it.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        startFg();
        if (web == null) show();
        return START_NOT_STICKY;
    }

    private void startFg() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("pad", "Джойстик", NotificationManager.IMPORTANCE_LOW));
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, PadService.class).setAction("stop"),
                PendingIntent.FLAG_IMMUTABLE);
        Notification n = new Notification.Builder(this, "pad").setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("Джойстик Fold2 AI").setContentText("Экран телефона - пульт для игры на мониторе")
                .addAction(new Notification.Action.Builder((Icon) null, "Закрыть", stop).build())
                .setOngoing(true).build();
        if (Build.VERSION.SDK_INT >= 34) startForeground(7, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(7, n);
    }

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private void show() {
        byte[] r = new byte[16];
        new SecureRandom().nextBytes(r);
        StringBuilder t = new StringBuilder();
        for (byte x : r) t.append(String.format("%02x", x));
        token = t.toString();
        script = "sh " + getExternalFilesDir(null).getAbsolutePath().replace("/storage/emulated/0", "/data/media/0")
                + "/f2ai/f2ai.sh ";
        vib = getSystemService(Vibrator.class);
        Display d0 = getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY);
        Context wc = createDisplayContext(d0).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null);
        wm = wc.getSystemService(WindowManager.class);
        web = new WebView(wc);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setSupportZoom(false);
        web.setBackgroundColor(Color.BLACK);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient());
        web.addJavascriptInterface(new Bridge(), "F2P");
        // системные жесты «назад» у краёв не перехватывают стики (до 200dp по высоте у каждого края - лимит Android)
        web.addOnLayoutChangeListener((v, l, tp, rt, b, ol, ot, orr, ob) -> {
            int h = Math.min(b - tp, (int) (200 * getResources().getDisplayMetrics().density)), w = rt - l;
            List<Rect> ex = new ArrayList<>();
            ex.add(new Rect(0, b - tp - h, 60, b - tp));
            ex.add(new Rect(w - 60, b - tp - h, w, b - tp));
            v.setSystemGestureExclusionRects(ex);
        });
        lp = new WindowManager.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                        | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.OPAQUE);
        lp.setTitle("Fold2 Pad");
        lp.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE;
        try {
            wm.addView(web, lp);
        } catch (Exception e) {
            Toast.makeText(this, "Джойстик: нет окна поверх других (" + e.getMessage() + ")", Toast.LENGTH_LONG).show();
            web.destroy();
            web = null;
            stopSelf();
            return;
        }
        running = true;
        web.loadUrl("file:///android_asset/pad.html");
    }

    /** из потока моста JS: сокет в главном потоке Android запрещает (NetworkOnMainThreadException) */
    synchronized void send(String m) {
        if (m == null || token == null) return;
        byte[] b = (token + " " + m).getBytes(StandardCharsets.UTF_8);
        try {
            if (sock == null) {
                sock = new DatagramSocket();
                sock.connect(InetAddress.getLoopbackAddress(), PORT);
            }
            sock.send(new DatagramPacket(b, b.length));
        } catch (Exception e) {
            if (sock != null) sock.close();
            sock = null;
        }
    }

    String ping() {
        try (DatagramSocket s = new DatagramSocket()) {
            s.setSoTimeout(400);
            s.connect(InetAddress.getLoopbackAddress(), PORT);
            byte[] b = (token + " p").getBytes(StandardCharsets.UTF_8);
            s.send(new DatagramPacket(b, b.length));
            byte[] in = new byte[128];
            DatagramPacket p = new DatagramPacket(in, in.length);
            s.receive(p);
            return new String(in, 0, p.getLength(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "";
        }
    }

    /** root-команда целиком: {"code": N, "out": "..."} */
    static String su(String cmd) {
        JSONObject j = new JSONObject();
        try {
            Process p = new ProcessBuilder("su", "-mm", "-c", cmd).redirectErrorStream(true).start();
            p.getOutputStream().close();
            StringBuilder o = new StringBuilder();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
            String line;
            while ((line = r.readLine()) != null) o.append(line).append('\n');
            j.put("code", p.waitFor());
            j.put("out", o.toString());
        } catch (Exception e) {
            try {
                j.put("code", -1);
                j.put("out", "нет root? " + e);
            } catch (Exception ignored) {
            }
        }
        return j.toString();
    }

    void cb(String id, String data) {
        final String js = "F2cb(" + JSONObject.quote(id) + ",'done'," + JSONObject.quote(data == null ? "" : data) + ")";
        ui.post(() -> {
            if (web != null) web.evaluateJavascript(js, null);
        });
    }

    private void setFocus(boolean f) {
        if (web == null) return;
        if (f) lp.flags &= ~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        else lp.flags |= WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        try {
            wm.updateViewLayout(web, lp);
        } catch (Exception ignored) {
        }
    }

    class Bridge {
        /** команды f2pad без ответа: "k 17 1;r 5 -2" */
        @JavascriptInterface
        public void pad(String m) {
            send(m);
        }

        @JavascriptInterface
        public void ping(String id) {
            pool.execute(() -> cb(id, PadService.this.ping()));  // ping() здесь - метод Bridge
        }

        /** (пере)запуск f2pad с токеном этого окна */
        @JavascriptInterface
        public void start(String id) {
            pool.execute(() -> cb(id, su("F2PAD_TOKEN=" + token + " " + script + "pad-start")));
        }

        @JavascriptInterface
        public void sh(String id, String cmd) {
            pool.execute(() -> cb(id, su(cmd)));
        }

        @JavascriptInterface
        public void focus(boolean f) {
            ui.post(() -> setFocus(f));
        }

        @JavascriptInterface
        public void vib(int ms) {
            try {
                if (vib != null && ms > 0) vib.vibrate(VibrationEffect.createOneShot(Math.min(ms, 200), VibrationEffect.DEFAULT_AMPLITUDE));
            } catch (Exception ignored) {
            }
        }

        /** 0 - как телефон, 1 - альбомная, 2 - книжная */
        @JavascriptInterface
        public void orient(int o) {
            ui.post(() -> {
                if (web == null) return;
                lp.screenOrientation = o == 1 ? ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        : o == 2 ? ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT : ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
                try {
                    wm.updateViewLayout(web, lp);
                } catch (Exception ignored) {
                }
            });
        }

        @JavascriptInterface
        public void close() {
            ui.post(PadService.this::stopSelf);
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        final String stop = script;
        new Thread(() -> {  // сеть - не из главного потока
            send("x;q");  // f2pad: отпустить всё, убрать устройства, выйти
            synchronized (this) {
                if (sock != null) sock.close();
                sock = null;
            }
            if (stop != null) su(stop + "pad-stop");
        }).start();
        if (web != null) {
            try {
                wm.removeView(web);
            } catch (Exception ignored) {
            }
            web.destroy();
            web = null;
        }
        pool.shutdown();
        super.onDestroy();
    }
}
