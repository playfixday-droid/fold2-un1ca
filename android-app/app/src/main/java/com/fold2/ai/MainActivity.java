package com.fold2.ai;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Fold2 AI: WebView-интерфейс (assets/index.html) + мост к root-командам, локальным серверам и микрофону. */
public class MainActivity extends Activity {
    private WebView web;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService pool = Executors.newCachedThreadPool();
    private File ext;
    private volatile boolean recording;
    private String pickId;
    private volatile boolean visible;
    private final Map<String, HttpURLConnection> conns = new ConcurrentHashMap<>();

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        ext = getExternalFilesDir(null);
        installAssets();
        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient());
        web.addJavascriptInterface(new Bridge(), "F2");
        setContentView(web);
        if (b != null) web.restoreState(b); else web.loadUrl("file:///android_asset/index.html");
    }

    @Override
    protected void onResume() {
        super.onResume();
        visible = true;
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.cancel(1);
    }

    @Override
    protected void onPause() {
        visible = false;
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override
    public void onBackPressed() {
        web.evaluateJavascript("typeof back==='function'&&back()", v -> { if (!"true".equals(v)) finish(); });
    }

    private void installAssets() {
        File d = new File(ext, "f2ai");
        d.mkdirs();
        for (String n : new String[]{"f2ai.sh", "ai_server.py"}) {
            try (InputStream in = getAssets().open(n); OutputStream out = new FileOutputStream(new File(d, n))) {
                copy(in, out);
            } catch (IOException ignored) {
            }
        }
    }

    static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[65536];
        int r;
        while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
    }

    static byte[] readBytes(InputStream in) throws IOException {
        if (in == null) return new byte[0];
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        copy(in, b);
        return b.toByteArray();
    }

    static String readAll(InputStream in) throws IOException {
        return new String(readBytes(in), StandardCharsets.UTF_8);
    }

    void cb(String id, String type, String data) {
        final String js = "F2cb(" + JSONObject.quote(id) + "," + JSONObject.quote(type) + ","
                + JSONObject.quote(data == null ? "" : data) + ")";
        ui.post(() -> web.evaluateJavascript(js, null));
    }

    static void writeWav(File f, byte[] pcm, int sr) throws IOException {
        try (DataOutputStream o = new DataOutputStream(new FileOutputStream(f))) {
            o.writeBytes("RIFF");
            o.writeInt(Integer.reverseBytes(36 + pcm.length));
            o.writeBytes("WAVEfmt ");
            o.writeInt(Integer.reverseBytes(16));
            o.writeShort(Short.reverseBytes((short) 1));
            o.writeShort(Short.reverseBytes((short) 1));
            o.writeInt(Integer.reverseBytes(sr));
            o.writeInt(Integer.reverseBytes(sr * 2));
            o.writeShort(Short.reverseBytes((short) 2));
            o.writeShort(Short.reverseBytes((short) 16));
            o.writeBytes("data");
            o.writeInt(Integer.reverseBytes(pcm.length));
            o.write(pcm);
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != 2 || pickId == null) return;
        final String id = pickId;
        pickId = null;
        if (res != RESULT_OK || data == null || data.getData() == null) {
            cb(id, "err", "файл не выбран");
            return;
        }
        final Uri u = data.getData();
        pool.execute(() -> {
            File f = new File(ext, "ref_pick.audio");
            try (InputStream in = getContentResolver().openInputStream(u); OutputStream o = new FileOutputStream(f)) {
                copy(in, o);
                cb(id, "done", f.getAbsolutePath());
            } catch (Exception e) {
                cb(id, "err", e.toString());
            }
        });
    }

    class Bridge {
        @JavascriptInterface
        public String dir() {
            return ext.getAbsolutePath();
        }

        /** root-команда (su -mm: общее пространство монтирования, как у debian.sh); построчный вывод. */
        @JavascriptInterface
        public void sh(String id, String cmd) {
            pool.execute(() -> {
                try {
                    Process p = new ProcessBuilder("su", "-mm", "-c", cmd).redirectErrorStream(true).start();
                    p.getOutputStream().close();
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
                    String line;
                    while ((line = r.readLine()) != null) cb(id, "line", line);
                    cb(id, "exit", String.valueOf(p.waitFor()));
                } catch (Exception e) {
                    cb(id, "err", "нет root? " + e);
                }
            });
        }

        /** HTTP к локальным серверам: mode = text | sse (поток "data: ...") | bin (base64 + заголовки X-*). */
        @JavascriptInterface
        public void http(String id, String method, String url, String body, String mode) {
            pool.execute(() -> {
                HttpURLConnection c = null;
                try {
                    c = (HttpURLConnection) new URL(url).openConnection();
                    conns.put(id, c);
                    c.setRequestMethod(method);
                    c.setConnectTimeout(3000);
                    c.setReadTimeout(60 * 60 * 1000);
                    if (body != null && !body.isEmpty()) {
                        byte[] bb = body.getBytes(StandardCharsets.UTF_8);
                        c.setDoOutput(true);
                        c.setRequestProperty("Content-Type", "application/json");
                        c.setFixedLengthStreamingMode(bb.length);
                        try (OutputStream o = c.getOutputStream()) {
                            o.write(bb);
                        }
                    }
                    int code = c.getResponseCode();
                    if (code >= 400) {
                        cb(id, "err", "HTTP " + code + ": " + readAll(c.getErrorStream()));
                        return;
                    }
                    InputStream in = c.getInputStream();
                    if ("sse".equals(mode)) {
                        BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
                        String line;
                        while ((line = r.readLine()) != null)
                            if (line.startsWith("data: ")) cb(id, "chunk", line.substring(6));
                        cb(id, "done", "");
                    } else if ("bin".equals(mode)) {
                        byte[] d = readBytes(in);
                        JSONObject h = new JSONObject();
                        for (String k : new String[]{"Content-Type", "X-Gen-Sec", "X-Audio-Sec", "X-File", "X-Backend", "X-Seed", "X-Size"}) {
                            String v = c.getHeaderField(k);
                            if (v != null) h.put(k, v);
                        }
                        h.put("b64", Base64.encodeToString(d, Base64.NO_WRAP));
                        cb(id, "done", h.toString());
                    } else {
                        cb(id, "done", readAll(in));
                    }
                } catch (Exception e) {
                    cb(id, "err", conns.containsKey(id) ? e.toString() : "отменено");
                } finally {
                    conns.remove(id);
                    if (c != null) c.disconnect();
                }
            });
        }

        /** Прервать запрос (стоп ответа чата: llama-server бросает генерацию, когда клиент отключился). */
        @JavascriptInterface
        public void cancel(String id) {
            final HttpURLConnection c = conns.remove(id);
            if (c != null) pool.execute(c::disconnect);
        }

        /** Уведомление о готовности (картинка/голос идут минутами) - только если приложение свернуто. */
        @JavascriptInterface
        public void notif(String title, String text) {
            if (visible) return;
            ui.post(() -> {
                try {
                    NotificationManager nm = getSystemService(NotificationManager.class);
                    if (nm == null) return;
                    if (Build.VERSION.SDK_INT >= 33
                            && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                        return;
                    nm.createNotificationChannel(new NotificationChannel("done", "Готово", NotificationManager.IMPORTANCE_HIGH));
                    Intent i = new Intent(MainActivity.this, MainActivity.class)
                            .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
                    PendingIntent pi = PendingIntent.getActivity(MainActivity.this, 0, i,
                            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
                    Notification n = new Notification.Builder(MainActivity.this, "done")
                            .setSmallIcon(android.R.drawable.stat_sys_download_done)
                            .setContentTitle(title).setContentText(text).setAutoCancel(true).setContentIntent(pi).build();
                    nm.notify(1, n);
                } catch (Exception ignored) {
                }
            });
        }

        /** Разрешение на уведомления (Android 13+) - спрашиваем один раз при первой долгой задаче. */
        @JavascriptInterface
        public void askNotify() {
            if (Build.VERSION.SDK_INT >= 33
                    && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                ui.post(() -> requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 3));
        }

        @SuppressLint("MissingPermission")
        @JavascriptInterface
        public void recStart(String id) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                ui.post(() -> requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, 1));
                cb(id, "err", "разреши микрофон и нажми «Записать» ещё раз");
                return;
            }
            if (recording) return;
            recording = true;
            pool.execute(() -> {
                final int sr = 24000;
                AudioRecord ar = null;
                ByteArrayOutputStream pcm = new ByteArrayOutputStream();
                try {
                    int min = AudioRecord.getMinBufferSize(sr, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                    ar = new AudioRecord(MediaRecorder.AudioSource.MIC, sr, AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT, Math.max(min, sr));
                    ar.startRecording();
                    byte[] buf = new byte[4800];
                    long t0 = System.currentTimeMillis();
                    while (recording && System.currentTimeMillis() - t0 < 30000) {
                        int n = ar.read(buf, 0, buf.length);
                        if (n > 0) pcm.write(buf, 0, n);
                    }
                    ar.stop();
                    File f = new File(ext, "ref_user.wav");
                    writeWav(f, pcm.toByteArray(), sr);
                    cb(id, "done", f.getAbsolutePath() + "|" + (pcm.size() / 2.0 / sr));
                } catch (Exception e) {
                    cb(id, "err", e.toString());
                } finally {
                    recording = false;
                    if (ar != null) ar.release();
                }
            });
        }

        @JavascriptInterface
        public void recStop() {
            recording = false;
        }

        @JavascriptInterface
        public void pick(String id) {
            pickId = id;
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(Intent.CATEGORY_OPENABLE);
            i.setType("audio/*");
            ui.post(() -> startActivityForResult(i, 2));
        }
    }
}
