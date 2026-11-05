package com.fold2.mon;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebChromeClient;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

/** Экран монитора: WebView (assets/index.html) + мост F2M; данные приходят из Hub раз в интервал. */
public class MainActivity extends Activity implements Hub.Listener {
    private WebView web;
    private Hub hub;
    private volatile boolean ready;
    private volatile long ival = 1000;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        hub = Hub.get(this);
        web = new WebView(this);
        WebSettings ws = web.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setAllowFileAccess(true);
        ws.setTextZoom(100);
        WebView.setWebContentsDebuggingEnabled(true);
        web.setBackgroundColor(Color.parseColor("#0b0f17"));
        web.setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView v, String url) { ready = true; String j = hub.lastJson; if (j != null) push(j); }
        });
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "F2M");
        web.loadUrl("file:///android_asset/index.html");
        setContentView(web);
    }

    @Override protected void onStart() { super.onStart(); hub.add(this, ival); }
    @Override protected void onStop() { hub.remove(this); super.onStop(); }

    private void push(String json) { web.post(() -> web.evaluateJavascript("window.onSample&&onSample(" + json + ")", null)); }
    @Override public void onSample(String json, JSONObject o) { if (ready) push(json); }

    @Override public void onBackPressed() {
        web.evaluateJavascript("window.onBack?onBack():false", v -> { if (!"true".equals(v)) back(); });
    }
    private void back() { super.onBackPressed(); }

    final class Bridge {
        @JavascriptInterface public void setInterval(int ms) { ival = Math.max(250, ms); hub.setInterval(MainActivity.this, ival); }
        @JavascriptInterface public void setSlow(boolean top, boolean rpc, int sec) { hub.wantTop = top; hub.wantRpc = rpc; hub.slowSec = Math.max(2, sec); }
        @JavascriptInterface public void setUnits(String cur, boolean inv) { hub.setUnits(cur, inv); }
        @JavascriptInterface public void setTempEvery(int n) { hub.tempEvery = Math.max(1, n); }
        @JavascriptInterface public void retryRoot() { hub.sh.retry = true; }
        @JavascriptInterface public void keepScreen(boolean on) {
            runOnUiThread(() -> { if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); });
        }
        @JavascriptInterface public void fullscreen(boolean on) {
            runOnUiThread(() -> {
                WindowInsetsController c = getWindow().getInsetsController(); if (c == null) return;
                if (on) { c.hide(WindowInsets.Type.systemBars()); c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE); }
                else c.show(WindowInsets.Type.systemBars());
            });
        }
        @JavascriptInterface public void orientation(String o) {
            runOnUiThread(() -> setRequestedOrientation("portrait".equals(o) ? ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    : "landscape".equals(o) ? ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED));
        }
        @JavascriptInterface public void bars(String color, boolean light) {
            runOnUiThread(() -> {
                try {
                    int c = Color.parseColor(color);
                    getWindow().setStatusBarColor(c); getWindow().setNavigationBarColor(c);
                    WindowInsetsController ic = getWindow().getInsetsController();
                    int m = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                    if (ic != null) ic.setSystemBarsAppearance(light ? m : 0, m);
                    web.setBackgroundColor(c);
                } catch (Exception ignored) { }
            });
        }
        @JavascriptInterface public String info() {
            JSONObject j = new JSONObject();
            try {
                j.put("ver", getPackageManager().getPackageInfo(getPackageName(), 0).versionName);
                j.put("model", Build.MODEL); j.put("dev", Build.DEVICE); j.put("android", Build.VERSION.RELEASE); j.put("sdk", Build.VERSION.SDK_INT);
                j.put("root", hub.sh.root);
                j.put("overlay", Settings.canDrawOverlays(MainActivity.this));
                j.put("notif", Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED);
            } catch (Exception ignored) { }
            return j.toString();
        }
        @JavascriptInterface public void service(String cfg) {
            getSharedPreferences("f2m", MODE_PRIVATE).edit().putString("svc", cfg).apply();
            runOnUiThread(() -> {
                JSONObject j = MonService.cfg(MainActivity.this);
                boolean ask = j.optBoolean("ask");
                if (ask && j.optBoolean("notif") && Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                    requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
                if (ask && j.optBoolean("overlay") && !Settings.canDrawOverlays(MainActivity.this))
                    try { startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getPackageName()))); } catch (Exception ignored) { }
                MonService.sync(MainActivity.this);
            });
        }
        @JavascriptInterface public void copy(String t) {
            runOnUiThread(() -> { ClipboardManager cm = getSystemService(ClipboardManager.class); if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("Fold2 Монитор", t)); });
        }
        @JavascriptInterface public String paste() {
            ClipboardManager cm = getSystemService(ClipboardManager.class);
            ClipData c = cm != null ? cm.getPrimaryClip() : null;
            return c != null && c.getItemCount() > 0 ? String.valueOf(c.getItemAt(0).coerceToText(MainActivity.this)) : "";
        }
        @JavascriptInterface public void ctl(String req) {
            new Thread(() -> {
                String r = hub.ctl.handle(req);
                if (req.contains("\"save\"")) runOnUiThread(() -> MonService.sync(MainActivity.this));
                web.post(() -> web.evaluateJavascript("window.onCtl&&onCtl(" + r.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029") + ")", null));
            }, "f2m-ctl").start();
        }
        @JavascriptInterface public void toast(String s) { runOnUiThread(() -> Toast.makeText(MainActivity.this, s, Toast.LENGTH_SHORT).show()); }
    }
}
