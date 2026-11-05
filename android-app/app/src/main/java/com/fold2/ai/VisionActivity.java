package com.fold2.ai;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.SurfaceTexture;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Size;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;
import org.tensorflow.lite.DataType;
import org.tensorflow.lite.Delegate;
import org.tensorflow.lite.Interpreter;
import org.tensorflow.lite.gpu.GpuDelegate;
import org.tensorflow.lite.nnapi.NnApiDelegate;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Зрение для чата: камера (Camera2, OIS + стабилизация превью) и детектор объектов COCO (SSD MobileNet v1 quant, TFLite)
 * на NPU (NNAPI -> Hexagon DSP), CPU или GPU. «Снимок» за ~1 с выбирает самый резкий кадр (резкость по лапласиану,
 * штраф за дрожание по гироскопу) и возвращает JPEG + найденные объекты в MainActivity (F2.vision).
 */
public class VisionActivity extends Activity implements SensorEventListener {
    static final String[] BACKENDS = {"NPU (NNAPI qti-dsp)", "NPU (NNAPI)", "CPU 4 потока", "GPU"};
    static final int IN = 300;
    static final Map<String, String> RU = new HashMap<>();

    static {
        String[] p = {"person", "человек", "bicycle", "велосипед", "car", "машина", "motorcycle", "мотоцикл", "airplane", "самолёт",
                "bus", "автобус", "train", "поезд", "truck", "грузовик", "boat", "лодка", "traffic light", "светофор",
                "fire hydrant", "гидрант", "stop sign", "знак «стоп»", "parking meter", "паркомат", "bench", "скамейка",
                "bird", "птица", "cat", "кошка", "dog", "собака", "horse", "лошадь", "sheep", "овца", "cow", "корова",
                "elephant", "слон", "bear", "медведь", "zebra", "зебра", "giraffe", "жираф", "backpack", "рюкзак",
                "umbrella", "зонт", "handbag", "сумка", "tie", "галстук", "suitcase", "чемодан", "frisbee", "фрисби",
                "skis", "лыжи", "snowboard", "сноуборд", "sports ball", "мяч", "kite", "воздушный змей",
                "baseball bat", "бейсбольная бита", "baseball glove", "бейсбольная перчатка", "skateboard", "скейтборд",
                "surfboard", "доска для сёрфинга", "tennis racket", "теннисная ракетка", "bottle", "бутылка",
                "wine glass", "бокал", "cup", "чашка", "fork", "вилка", "knife", "нож", "spoon", "ложка", "bowl", "миска",
                "banana", "банан", "apple", "яблоко", "sandwich", "бутерброд", "orange", "апельсин", "broccoli", "брокколи",
                "carrot", "морковь", "hot dog", "хот-дог", "pizza", "пицца", "donut", "пончик", "cake", "торт",
                "chair", "стул", "couch", "диван", "potted plant", "растение в горшке", "bed", "кровать",
                "dining table", "стол", "toilet", "унитаз", "tv", "телевизор", "laptop", "ноутбук", "mouse", "мышь",
                "remote", "пульт", "keyboard", "клавиатура", "cell phone", "телефон", "microwave", "микроволновка",
                "oven", "духовка", "toaster", "тостер", "sink", "раковина", "refrigerator", "холодильник", "book", "книга",
                "clock", "часы", "vase", "ваза", "scissors", "ножницы", "teddy bear", "плюшевый мишка",
                "hair drier", "фен", "toothbrush", "зубная щётка"};
        for (int i = 0; i < p.length; i += 2) RU.put(p[i], p[i + 1]);
    }

    static class Det {
        String en, ru;
        float score;
        RectF box;  // 0..1 относительно кадра на экране
    }

    /** Объект, прослеженный по кадрам: рамка и уверенность сглажены, метка - по «голосам» прошлых кадров */
    static class Trk {
        String en;
        float score;
        RectF box;
        int hits, miss;
        final Map<String, Float> votes = new HashMap<>();
    }

    // из «Мощность» в приложении: порог уверенности и сколько кадров подряд объект должен быть виден
    private float confShow = 0.55f, confKeep = 0.4f;
    private int hold = 3;
    private final List<Trk> trks = new ArrayList<>();
    private volatile boolean trkReset;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private FrameLayout stage;
    private TextureView tv;
    private Overlay ov;
    private TextView info;
    private Button bBack, bEis, bShot;
    private HandlerThread camT, detT;
    private Handler camH, detH;
    private CameraDevice cam;
    private CameraCaptureSession ses;
    private Size prev;
    private int sensorOri = 90, rotExtra;
    private boolean hasOis, hasEis, hasPrevStab, eisOn = true;
    private String stab = "";
    private volatile boolean opening;
    private volatile Interpreter tfl;
    private Delegate dlg;
    private volatile int mode;
    private volatile String backend = "загрузка детектора…";
    private volatile boolean busy, alive;
    private final List<String> labels = new ArrayList<>();
    private volatile List<Det> dets = new ArrayList<>();
    private Bitmap inBmp;
    private ByteBuffer inBuf;
    private final float[][][] oBox = new float[1][10][4];
    private final float[][] oCls = new float[1][10], oSc = new float[1][10];
    private final float[] oN = new float[1];
    private volatile double ms;
    private int frames;
    private long fpsT0;
    private double fps;
    private SensorManager sm;
    private volatile float gyro;
    // снимок
    private boolean shooting;
    private long shotT0, lastGrab;
    private Bitmap best;
    private double bestScore = -1, bestSharp;
    private float bestGyro;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        Intent in = getIntent();
        if (in != null) {
            int be = in.getIntExtra("be", -1);
            if (be >= 0 && be < BACKENDS.length) mode = be;
            confShow = Math.max(0.2f, Math.min(0.95f, in.getFloatExtra("conf", confShow)));
            confKeep = Math.max(0.2f, confShow - 0.15f);
            hold = Math.max(1, Math.min(8, in.getIntExtra("hold", hold)));
        }
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        stage = new FrameLayout(this);
        tv = new TextureView(this);
        ov = new Overlay();
        stage.addView(tv, new FrameLayout.LayoutParams(1, 1, Gravity.CENTER));
        stage.addView(ov, new FrameLayout.LayoutParams(1, 1, Gravity.CENTER));
        root.addView(stage, new FrameLayout.LayoutParams(-1, -1));
        info = new TextView(this);
        info.setTextColor(Color.WHITE);
        info.setTextSize(13);
        info.setBackgroundColor(0x88000000);
        info.setPadding(16, 10, 16, 10);
        root.addView(info, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));
        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER);
        bar.setBackgroundColor(0x88000000);
        bBack = btn(bar, "NPU", v -> switchBackend());
        bEis = btn(bar, "EIS вкл", v -> {
            eisOn = !eisOn;
            camH.post(this::startPreview);
        });
        btn(bar, "⟳", v -> {
            rotExtra = (rotExtra + 1) % 4;
            layoutPreview();
        });
        bShot = btn(bar, "◉ Снимок → ИИ", v -> shot());
        btn(bar, "✕", v -> {
            setResult(RESULT_CANCELED);
            finish();
        });
        root.addView(bar, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        setContentView(root);
        stage.addOnLayoutChangeListener((v, l, t, r, bt, ol, ot, or, ob) -> {
            if (r - l != or - ol || bt - t != ob - ot) layoutPreview();
        });
        mode = getSharedPreferences("vision", MODE_PRIVATE).getInt("mode", 0);
        rotExtra = getSharedPreferences("vision", MODE_PRIVATE).getInt("rot", 0);
        sm = getSystemService(SensorManager.class);
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.CAMERA}, 5);
    }

    private Button btn(LinearLayout bar, String t, View.OnClickListener l) {
        Button x = new Button(this);
        x.setText(t);
        x.setAllCaps(false);
        x.setOnClickListener(l);
        bar.addView(x, new LinearLayout.LayoutParams(-2, -2));
        return x;
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] p, int[] r) {
        if (req != 5) return;
        // разрешено - камеру откроет onResume (окно разрешения ставило активити на паузу)
        if (r.length == 0 || r[0] != PackageManager.PERMISSION_GRANTED) {
            setResult(RESULT_CANCELED, new Intent().putExtra("err", "нет разрешения на камеру"));
            finish();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        alive = true;
        camT = new HandlerThread("cam");
        camT.start();
        camH = new Handler(camT.getLooper());
        detT = new HandlerThread("det");
        detT.start();
        detH = new Handler(detT.getLooper());
        detH.post(() -> makeTfl(mode));
        Sensor g = sm == null ? null : sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        if (g != null) sm.registerListener(this, g, SensorManager.SENSOR_DELAY_GAME);
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) begin();
        ui.post(tick);
    }

    @Override
    protected void onPause() {
        alive = false;
        ui.removeCallbacks(tick);
        if (sm != null) sm.unregisterListener(this);
        closeCam();
        final HandlerThread d = detT;
        detH.post(() -> {
            closeTfl();
            d.quitSafely();
        });
        camT.quitSafely();
        getSharedPreferences("vision", MODE_PRIVATE).edit().putInt("mode", mode).putInt("rot", rotExtra).apply();
        super.onPause();
    }

    private void begin() {
        if (tv.isAvailable()) camH.post(this::openCam);
        else tv.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            public void onSurfaceTextureAvailable(SurfaceTexture s, int w, int h) {
                if (alive) camH.post(VisionActivity.this::openCam);
            }

            public void onSurfaceTextureSizeChanged(SurfaceTexture s, int w, int h) {
            }

            public boolean onSurfaceTextureDestroyed(SurfaceTexture s) {
                return true;
            }

            public void onSurfaceTextureUpdated(SurfaceTexture s) {
            }
        });
    }

    // ---------- камера
    private void openCam() {
        if (cam != null || opening) return;
        opening = true;
        try {
            CameraManager cm = getSystemService(CameraManager.class);
            String id = null;
            CameraCharacteristics ch = null;
            for (String c : cm.getCameraIdList()) {
                CameraCharacteristics x = cm.getCameraCharacteristics(c);
                Integer f = x.get(CameraCharacteristics.LENS_FACING);
                if (f != null && f == CameraCharacteristics.LENS_FACING_BACK) {
                    id = c;
                    ch = x;
                    break;
                }
            }
            if (id == null) {
                opening = false;
                status("нет задней камеры");
                return;
            }
            StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            prev = pickSize(map.getOutputSizes(SurfaceTexture.class));
            Integer so = ch.get(CameraCharacteristics.SENSOR_ORIENTATION);
            sensorOri = so == null ? 90 : so;
            hasOis = has(ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION),
                    CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON);
            int[] vs = ch.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES);
            hasPrevStab = Build.VERSION.SDK_INT >= 33 && has(vs, CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_PREVIEW_STABILIZATION);
            hasEis = hasPrevStab || has(vs, CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON);
            ui.post(this::layoutPreview);
            cm.openCamera(id, new CameraDevice.StateCallback() {
                public void onOpened(CameraDevice c) {
                    opening = false;
                    if (!alive) {
                        c.close();
                        return;
                    }
                    cam = c;
                    startPreview();
                }

                public void onDisconnected(CameraDevice c) {
                    opening = false;
                    c.close();
                    cam = null;
                }

                public void onError(CameraDevice c, int e) {
                    opening = false;
                    c.close();
                    cam = null;
                    status("ошибка камеры " + e + " (занята другим приложением?)");
                }
            }, camH);
        } catch (SecurityException e) {
            opening = false;
            status("нет разрешения на камеру");
        } catch (Exception e) {
            opening = false;
            status("камера: " + e);
        }
    }

    static boolean has(int[] a, int v) {
        if (a != null) for (int x : a) if (x == v) return true;
        return false;
    }

    /** 4:3 не больше 1440x1080 (для превью и детектора хватает, меньше нагрузка), иначе ближайший */
    static Size pickSize(Size[] all) {
        Size best = all[0];
        long bs = Long.MAX_VALUE;
        for (Size s : all) {
            long area = (long) s.getWidth() * s.getHeight();
            double ar = (double) s.getWidth() / s.getHeight();
            long score = Math.abs(area - 1440L * 1080) + (Math.abs(ar - 4.0 / 3) < 0.02 ? 0 : 4_000_000L)
                    + (area > 1920L * 1440 ? 8_000_000L : 0);
            if (score < bs) {
                bs = score;
                best = s;
            }
        }
        return best;
    }

    private void startPreview() {
        if (cam == null || !tv.isAvailable()) return;
        try {
            if (ses != null) {
                ses.close();
                ses = null;
            }
            SurfaceTexture st = tv.getSurfaceTexture();
            st.setDefaultBufferSize(prev.getWidth(), prev.getHeight());
            Surface s = new Surface(st);
            final CaptureRequest.Builder b = cam.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
            b.addTarget(s);
            b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
            List<String> on = new ArrayList<>();
            if (hasOis) {
                b.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON);
                on.add("OIS");
            }
            if (hasEis && eisOn) {
                b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, hasPrevStab
                        ? CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_PREVIEW_STABILIZATION
                        : CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON);
                on.add(hasPrevStab ? "EIS превью" : "EIS");
            } else {
                b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF);
            }
            stab = on.isEmpty() ? "стабилизации нет" : "стабилизация: " + String.join(" + ", on) + " + выбор резкого кадра";
            ui.post(() -> bEis.setText(!hasEis ? "EIS нет" : eisOn ? "EIS вкл" : "EIS выкл"));
            cam.createCaptureSession(Arrays.asList(s), new CameraCaptureSession.StateCallback() {
                public void onConfigured(CameraCaptureSession ss) {
                    if (cam == null) return;
                    ses = ss;
                    try {
                        ss.setRepeatingRequest(b.build(), null, camH);
                    } catch (Exception e) {
                        status("превью: " + e);
                    }
                }

                public void onConfigureFailed(CameraCaptureSession ss) {
                    status("камера не настроилась" + (eisOn ? " - попробуйте EIS выкл" : ""));
                }
            }, camH);
        } catch (Exception e) {
            status("превью: " + e);
        }
    }

    private void closeCam() {
        try {
            if (ses != null) ses.close();
        } catch (Exception ignored) {
        }
        ses = null;
        if (cam != null) cam.close();
        cam = null;
    }

    /** Размер TextureView под пропорции кадра + поворот (как в Camera2Basic); ⟳ - доп. поворот (DeX, стол) */
    private void layoutPreview() {
        if (prev == null || stage.getWidth() == 0) return;
        int dr = getDisplay() == null ? 0 : getDisplay().getRotation();
        int rot = (dr + rotExtra) % 4;
        boolean side = rot == Surface.ROTATION_90 || rot == Surface.ROTATION_270;
        boolean portrait = (sensorOri == 90 || sensorOri == 270) != side;
        float cw = portrait ? prev.getHeight() : prev.getWidth(), chh = portrait ? prev.getWidth() : prev.getHeight();
        float k = Math.min(stage.getWidth() / cw, stage.getHeight() / chh);
        int vw = Math.round(cw * k), vh = Math.round(chh * k);
        for (View v : new View[]{tv, ov}) v.setLayoutParams(new FrameLayout.LayoutParams(vw, vh, Gravity.CENTER));
        Matrix m = new Matrix();
        float cx = vw / 2f, cy = vh / 2f;
        if (side) {
            RectF view = new RectF(0, 0, vw, vh), buf = new RectF(0, 0, vh, vw);
            buf.offset(cx - buf.centerX(), cy - buf.centerY());
            m.setRectToRect(view, buf, Matrix.ScaleToFit.FILL);
            m.postRotate(90 * (rot - 2), cx, cy);
        } else if (rot == Surface.ROTATION_180) {
            m.postRotate(180, cx, cy);
        }
        tv.setTransform(m);
        dets = new ArrayList<>();
        trkReset = true;  // кадр повернулся - прошлые рамки не к месту (чистит поток детектора)
    }

    // ---------- детектор
    private void makeTfl(int want) {
        closeTfl();
        ByteBuffer model;
        try {
            model = asset("vision/detect.tflite");
            labels.clear();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(getAssets().open("vision/labelmap.txt"), StandardCharsets.UTF_8))) {
                String l;
                while ((l = r.readLine()) != null) labels.add(l.trim());
            }
        } catch (Exception e) {
            backend = "нет модели детектора в APK: " + e;
            return;
        }
        StringBuilder why = new StringBuilder();
        for (int k = 0; k < BACKENDS.length; k++) {
            int mm = (want + k) % BACKENDS.length;
            Delegate d = null;
            try {
                Interpreter.Options o = new Interpreter.Options();
                if (mm <= 1) {
                    NnApiDelegate.Options no = new NnApiDelegate.Options();
                    no.setUseNnapiCpu(false);  // без nnapi-reference: только настоящий ускоритель, остальное - TFLite CPU
                    no.setAllowFp16(true);
                    no.setExecutionPreference(NnApiDelegate.Options.EXECUTION_PREFERENCE_SUSTAINED_SPEED);
                    if (mm == 0) no.setAcceleratorName("qti-dsp");
                    d = new NnApiDelegate(no);
                } else if (mm == 3) {
                    d = new GpuDelegate();
                }
                o.setNumThreads(mm == 2 ? 4 : 2);
                if (d != null) o.addDelegate(d);
                Interpreter it = new Interpreter(model, o);
                int[] sh = it.getInputTensor(0).shape();
                boolean u8 = it.getInputTensor(0).dataType() == DataType.UINT8;
                inBuf = ByteBuffer.allocateDirect(sh[1] * sh[2] * 3 * (u8 ? 1 : 4)).order(ByteOrder.nativeOrder());
                inBmp = Bitmap.createBitmap(sh[2], sh[1], Bitmap.Config.ARGB_8888);
                tfl = it;
                dlg = d;
                mode = mm;
                backend = BACKENDS[mm] + (why.length() > 0 ? " (не вышло: " + why + ")" : "");
                ms = 0;
                ui.post(() -> bBack.setText(mm <= 1 ? "NPU" : mm == 2 ? "CPU" : "GPU"));
                return;
            } catch (Throwable e) {
                closeDelegate(d);
                if (why.length() > 0) why.append(", ");
                why.append(BACKENDS[mm]);
            }
        }
        backend = "детектор не запустился: " + why;
    }

    private void closeDelegate(Delegate d) {
        try {
            if (d instanceof NnApiDelegate) ((NnApiDelegate) d).close();
            else if (d instanceof GpuDelegate) ((GpuDelegate) d).close();
        } catch (Throwable ignored) {
        }
    }

    private void closeTfl() {
        if (tfl != null) tfl.close();
        tfl = null;
        closeDelegate(dlg);
        dlg = null;
    }

    private void switchBackend() {
        // NPU(qti-dsp) -> CPU -> GPU -> NPU; NNAPI «без имени» - запасной для NPU
        final int next = mode <= 1 ? 2 : mode == 2 ? 3 : 0;
        backend = "переключаю на " + BACKENDS[next] + "…";
        detH.post(() -> makeTfl(next));
    }

    private ByteBuffer asset(String n) throws Exception {
        byte[] a;
        try (InputStream in = getAssets().open(n)) {
            a = MainActivity.readBytes(in);
        }
        ByteBuffer b = ByteBuffer.allocateDirect(a.length).order(ByteOrder.nativeOrder());
        b.put(a).rewind();
        return b;
    }

    private final Runnable tick = new Runnable() {
        public void run() {
            if (!alive) return;
            ui.postDelayed(this, 15);
            if (!tv.isAvailable()) return;
            long now = System.currentTimeMillis();
            if (shooting && now - lastGrab >= 90) {
                lastGrab = now;
                grabForShot();
                if (now - shotT0 > 1100) finishShot();
            }
            final Interpreter it = tfl;
            if (busy || it == null || inBmp == null) return;
            busy = true;
            final Bitmap bm = tv.getBitmap(inBmp);
            if (bm == null) {
                busy = false;
                return;
            }
            detH.post(() -> detect(it, bm));
        }
    };

    private void detect(Interpreter it, Bitmap bm) {
        try {
            if (it != tfl) return;
            int w = bm.getWidth(), h = bm.getHeight();
            int[] px = new int[w * h];
            bm.getPixels(px, 0, w, 0, 0, w, h);
            inBuf.rewind();
            boolean u8 = it.getInputTensor(0).dataType() == DataType.UINT8;
            for (int p : px) {
                int r = (p >> 16) & 255, g = (p >> 8) & 255, bl = p & 255;
                if (u8) {
                    inBuf.put((byte) r).put((byte) g).put((byte) bl);
                } else {
                    inBuf.putFloat((r - 127.5f) / 127.5f).putFloat((g - 127.5f) / 127.5f).putFloat((bl - 127.5f) / 127.5f);
                }
            }
            inBuf.rewind();
            Map<Integer, Object> out = new HashMap<>();
            out.put(0, oBox);
            out.put(1, oCls);
            out.put(2, oSc);
            out.put(3, oN);
            long t = System.nanoTime();
            it.runForMultipleInputsOutputs(new Object[]{inBuf}, out);
            double dt = (System.nanoTime() - t) / 1e6;
            ms = ms == 0 ? dt : ms * 0.85 + dt * 0.15;
            List<Det> res = new ArrayList<>();
            int n = Math.min(10, Math.round(oN[0]));
            for (int i = 0; i < n; i++) {
                if (oSc[0][i] < confKeep) continue;
                Det d = new Det();
                int c = Math.round(oCls[0][i]) + 1;  // labelmap.txt: первая строка «???»
                d.en = c >= 0 && c < labels.size() ? labels.get(c) : "?";
                d.ru = RU.containsKey(d.en) ? RU.get(d.en) : d.en;
                d.score = oSc[0][i];
                float[] bx = oBox[0][i];
                d.box = new RectF(clamp(bx[1]), clamp(bx[0]), clamp(bx[3]), clamp(bx[2]));
                res.add(d);
            }
            dets = track(res);
            frames++;
            long now = System.currentTimeMillis();
            if (now - fpsT0 > 1000) {
                fps = frames * 1000.0 / (now - fpsT0);
                frames = 0;
                fpsT0 = now;
            }
            ui.post(() -> {
                ov.invalidate();
                info.setText(String.format("%s · %.0f мс · %.1f к/с\n%s · дрожание %.2f рад/с%s", backend, ms, fps, stab, gyro,
                        shooting ? "\nснимаю: держите ровно…" : ""));
            });
        } catch (Throwable e) {
            backend = "ошибка детектора: " + e;
        } finally {
            busy = false;
        }
    }

    static float clamp(float v) {
        return Math.max(0f, Math.min(1f, v));
    }

    /**
     * Рамки не дрожат и не мигают: каждое обнаружение привязывается к прослеженному объекту (лучшее перекрытие,
     * класс может «прыгать» - метка по голосам), рамка и уверенность сглаживаются (почти неподвижная рамка - сильнее).
     * Новый объект показывается, только если виден hold кадров подряд с уверенностью не ниже confShow;
     * пропавший держится ещё hold кадров (одиночный пропуск детектора не гасит рамку).
     */
    private List<Det> track(List<Det> cur) {
        if (trkReset) {
            trkReset = false;
            trks.clear();
        }
        boolean[] used = new boolean[cur.size()];
        for (Trk t : trks) {
            int bi = -1;
            float bv = 0.3f;
            for (int i = 0; i < cur.size(); i++) {
                if (used[i]) continue;
                float v = iou(t.box, cur.get(i).box);
                if (v > bv) {
                    bv = v;
                    bi = i;
                }
            }
            for (Map.Entry<String, Float> e : t.votes.entrySet()) e.setValue(e.getValue() * 0.85f);
            if (bi >= 0) {
                used[bi] = true;
                Det d = cur.get(bi);
                float a = bv > 0.85f ? 0.2f : bv > 0.6f ? 0.4f : 0.7f;  // доля нового кадра: дрожание гасим, движение догоняем
                t.box = new RectF(mix(t.box.left, d.box.left, a), mix(t.box.top, d.box.top, a),
                        mix(t.box.right, d.box.right, a), mix(t.box.bottom, d.box.bottom, a));
                t.score = t.score * 0.6f + d.score * 0.4f;
                Float v = t.votes.get(d.en);
                t.votes.put(d.en, (v == null ? 0f : v) + d.score);
                float best = -1;
                for (Map.Entry<String, Float> e : t.votes.entrySet()) {
                    if (e.getValue() > best) {
                        best = e.getValue();
                        t.en = e.getKey();
                    }
                }
                t.hits++;
                t.miss = 0;
            } else {
                t.miss++;
                t.score *= 0.9f;
            }
        }
        for (int i = trks.size() - 1; i >= 0; i--) {
            Trk t = trks.get(i);
            if (t.miss > hold || (t.hits < hold && t.miss > 0)) trks.remove(i);
        }
        for (int i = 0; i < cur.size(); i++) {
            Det d = cur.get(i);
            if (used[i] || d.score < confShow) continue;
            Trk t = new Trk();
            t.en = d.en;
            t.score = d.score;
            t.box = d.box;
            t.hits = 1;
            t.votes.put(d.en, d.score);
            trks.add(t);
        }
        List<Det> out = new ArrayList<>();
        for (Trk t : trks) {
            if (t.hits < hold || t.score < confKeep) continue;
            Det d = new Det();
            d.en = t.en;
            d.ru = RU.containsKey(t.en) ? RU.get(t.en) : t.en;
            d.score = t.score;
            d.box = t.box;
            out.add(d);
        }
        return out;
    }

    static float mix(float a, float b, float k) {
        return a * (1 - k) + b * k;
    }

    static float iou(RectF a, RectF b) {
        float x0 = Math.max(a.left, b.left), y0 = Math.max(a.top, b.top), x1 = Math.min(a.right, b.right), y1 = Math.min(a.bottom, b.bottom);
        float in = Math.max(0, x1 - x0) * Math.max(0, y1 - y0);
        float u = a.width() * a.height() + b.width() * b.height() - in;
        return u <= 0 ? 0 : in / u;
    }

    // ---------- снимок для ИИ
    private void shot() {
        if (shooting || !tv.isAvailable()) return;
        shooting = true;
        shotT0 = System.currentTimeMillis();
        lastGrab = 0;
        best = null;
        bestScore = -1;
        bShot.setEnabled(false);
    }

    private void grabForShot() {
        int w = tv.getWidth(), h = tv.getHeight();
        if (w <= 0 || h <= 0) return;
        float k = 768f / Math.max(w, h);  // ~768 px по длинной стороне: VLM читает ~300-600 токенов картинки
        final Bitmap bm = tv.getBitmap(Math.max(1, Math.round(w * k)), Math.max(1, Math.round(h * k)));
        if (bm == null) return;
        final float g = gyro;
        double sharp = sharpness(bm);
        double sc = sharp / (1 + 4 * g);
        if (sc > bestScore) {
            if (best != null) best.recycle();
            best = bm;
            bestScore = sc;
            bestSharp = sharp;
            bestGyro = g;
        } else {
            bm.recycle();
        }
    }

    /** дисперсия лапласиана яркости на уменьшенной копии - чем больше, тем резче */
    static double sharpness(Bitmap bm) {
        Bitmap s = Bitmap.createScaledBitmap(bm, 192, Math.max(8, 192 * bm.getHeight() / bm.getWidth()), true);
        int w = s.getWidth(), h = s.getHeight();
        int[] px = new int[w * h];
        s.getPixels(px, 0, w, 0, 0, w, h);
        s.recycle();
        float[] y = new float[w * h];
        for (int i = 0; i < px.length; i++) {
            int p = px[i];
            y[i] = 0.299f * ((p >> 16) & 255) + 0.587f * ((p >> 8) & 255) + 0.114f * (p & 255);
        }
        double sum = 0, sq = 0;
        int n = 0;
        for (int r = 1; r < h - 1; r++)
            for (int c = 1; c < w - 1; c++) {
                int i = r * w + c;
                double l = 4 * y[i] - y[i - 1] - y[i + 1] - y[i - w] - y[i + w];
                sum += l;
                sq += l * l;
                n++;
            }
        double m = sum / Math.max(1, n);
        return sq / Math.max(1, n) - m * m;
    }

    private void finishShot() {
        shooting = false;
        bShot.setEnabled(true);
        if (best == null) {
            status("снимок не получился");
            return;
        }
        final Bitmap bm = best;
        best = null;
        final List<Det> ds = dets;
        final String be = backend, st = stab;
        final double sh = bestSharp, g = bestGyro, m = ms;
        new Thread(() -> {
            try {
                File dir = new File(getExternalFilesDir(null), "vision");
                dir.mkdirs();
                File f = new File(dir, "shot.jpg");
                try (FileOutputStream o = new FileOutputStream(f)) {
                    bm.compress(Bitmap.CompressFormat.JPEG, 88, o);
                }
                JSONObject j = new JSONObject();
                j.put("path", f.getAbsolutePath());
                j.put("w", bm.getWidth());
                j.put("h", bm.getHeight());
                j.put("backend", be);
                j.put("ms", Math.round(m));
                j.put("stab", st);
                j.put("sharp", Math.round(sh));
                j.put("gyro", Math.round(g * 100) / 100.0);
                JSONArray a = new JSONArray();
                for (Det d : ds) {
                    JSONObject x = new JSONObject();
                    x.put("label", d.ru);
                    x.put("en", d.en);
                    x.put("score", Math.round(d.score * 100));
                    x.put("box", new JSONArray(new double[]{r2(d.box.left), r2(d.box.top), r2(d.box.right), r2(d.box.bottom)}));
                    a.put(x);
                }
                j.put("dets", a);
                ui.post(() -> {
                    setResult(RESULT_OK, new Intent().putExtra("json", j.toString()));
                    finish();
                });
            } catch (Exception e) {
                status("снимок: " + e);
            }
        }).start();
    }

    static double r2(float v) {
        return Math.round(v * 100) / 100.0;
    }

    private void status(String s) {
        ui.post(() -> info.setText(s));
    }

    @Override
    public void onSensorChanged(SensorEvent e) {
        float x = e.values[0], y = e.values[1], z = e.values[2];
        gyro = gyro * 0.8f + 0.2f * (float) Math.sqrt(x * x + y * y + z * z);
    }

    @Override
    public void onAccuracyChanged(Sensor s, int a) {
    }

    /** рамки и подписи найденных объектов поверх превью */
    class Overlay extends View {
        final Paint box = new Paint(), txt = new Paint(), bg = new Paint();

        Overlay() {
            super(VisionActivity.this);
            box.setStyle(Paint.Style.STROKE);
            box.setStrokeWidth(5);
            box.setColor(0xFF3D8BFD);
            txt.setColor(Color.WHITE);
            txt.setTextSize(38);
            txt.setAntiAlias(true);
            bg.setColor(0xCC3D8BFD);
        }

        @Override
        protected void onDraw(Canvas c) {
            int w = getWidth(), h = getHeight();
            for (Det d : dets) {
                RectF r = new RectF(d.box.left * w, d.box.top * h, d.box.right * w, d.box.bottom * h);
                c.drawRect(r, box);
                String s = d.ru + " " + Math.round(d.score * 100) + "%";
                float tw = txt.measureText(s);
                float ty = Math.max(44, r.top);
                c.drawRect(r.left, ty - 44, r.left + tw + 16, ty, bg);
                c.drawText(s, r.left + 8, ty - 10, txt);
            }
        }
    }
}
