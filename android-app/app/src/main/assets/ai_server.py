#!/usr/bin/env python3
# Fold2 AI: сервер в Debian на 127.0.0.1:8082 - клон голоса (Qwen3-TTS 0.6B Base) и картинки (FLUX.2 klein 4B,
# stable-diffusion.cpp). Голос: qwentts.cpp (GGML, Q8_0, в разы быстрее) если собран, иначе PyTorch (fp32, медленно).
import gc, json, os, re, subprocess, threading, time, traceback, wave
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

M = "/sdcard/models"; OUT = M + "/out"
TTS_DIR = M + "/qwen3-tts-0.6b-base"
SD = "/opt/stable-diffusion.cpp/build/bin/sd-cli"
FLUX = [M + "/flux2/flux-2-klein-4b-Q4_0.gguf", M + "/flux2/flux2-vae.safetensors", M + "/flux2/Qwen3-4B-Q4_0.gguf"]
SAMPLE = OUT + "/ref_clone.wav"
SAMPLE_TEXT = ("Okay. Yeah. I resent you. I love you. I respect you. But you know what? You blew it! "
               "And thanks to you.")
QT = "/opt/qwentts.cpp/build/qwen-tts"
QTM = [M + "/qwentts/qwen-talker-0.6b-base-Q8_0.gguf", M + "/qwentts/qwen-tokenizer-12hz-Q8_0.gguf"]
QT_CFG = M + "/qwentts/qt.json"  # необязательная настройка без пересборки: {"cpus": "4-7", "args": ["--codec-chunk-dur", "4"]}


def qt_cfg():
    try:
        with open(QT_CFG) as f:
            return json.load(f)
    except Exception:
        return {}
os.makedirs(OUT, exist_ok=True)
work = threading.Lock()
st = {"tts": None, "prompts": {}, "progress": "", "busy": ""}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def load_tts():
    if st["tts"] is None:
        st["progress"] = "загрузка модели TTS"
        import torch
        from qwen_tts import Qwen3TTSModel
        torch.set_num_threads(4)
        t = time.time()
        st["tts"] = Qwen3TTSModel.from_pretrained(TTS_DIR, device_map="cpu", dtype=torch.float32)
        log("TTS загружен за %.1f с" % (time.time() - t))
    return st["tts"]


def unload_tts():
    if st["tts"] is not None:
        st["tts"] = None
        st["prompts"] = {}
        gc.collect()
        log("TTS выгружен")


def to_wav(src):
    s = os.stat(src)
    dst = "/tmp/ref_%d_%d.wav" % (s.st_size, int(s.st_mtime))
    if not os.path.exists(dst):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-ac", "1", "-ar", "24000", "-t", "20", dst],
                       check=True)
    return dst


def qt_ok():
    return os.access(QT, os.X_OK) and all(os.path.exists(f) for f in QTM)


def max_new(text):
    # 12 кадров кодека на секунду звука; ~15 символов/с речи -> запас x1.6, но не меньше 10 с и не больше ~170 с
    return int(min(2048, max(120, len(text) * 1.6 + 48)))


def wav_sec(fn):
    with wave.open(fn) as w:
        return w.getnframes() / float(w.getframerate())


def qt_lang(lang, text):
    if lang and lang != "Auto":
        return lang
    return "Russian" if re.search("[а-яА-ЯёЁ]", text) else "English"


def do_tts_qt(text, ref, ref_text, lang):
    unload_tts()
    fn = OUT + "/tts_%s.wav" % time.strftime("%Y%m%d_%H%M%S")
    cfg = qt_cfg()
    cmd = ["taskset", "-c", str(cfg.get("cpus", "0-7")), QT, "--model", QTM[0], "--codec", QTM[1],
           "--lang", qt_lang(lang, text), "--ref-wav", ref, "--max-new", str(max_new(text))] + \
        [str(a) for a in cfg.get("args", [])] + ["-o", fn]
    if ref_text:
        with open("/tmp/ref_text.txt", "w") as f:
            f.write(ref_text + "\n")
        cmd[-2:-2] = ["--ref-text", "/tmp/ref_text.txt"]
    st["progress"] = "синтез (qwentts.cpp)"
    t = time.time()
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         errors="replace")
    p.stdin.write(text + "\n")
    p.stdin.close()
    tail = []
    for line in p.stdout:
        line = line.strip()
        if line:
            st["progress"] = line[-160:]
            tail = (tail + [line])[-15:]
    rc = p.wait()
    dt = time.time() - t
    if rc != 0 or not os.path.exists(fn):
        raise RuntimeError("qwen-tts код %d:\n%s" % (rc, "\n".join(tail)))
    log("qwen-tts:", " | ".join(tail[-4:]))
    return fn, {"X-Gen-Sec": "%.2f" % dt, "X-Audio-Sec": "%.2f" % wav_sec(fn), "X-Backend": "qwentts.cpp Q8_0"}


def do_tts(req):
    text = (req.get("text") or "").strip()
    if not text:
        raise ValueError("пустой текст")
    if not os.path.exists(SAMPLE) and not req.get("ref_audio"):
        subprocess.run(["curl", "-fsSL", "-o", SAMPLE,
                        "https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-TTS-Repo/clone.wav"], check=True)
    if qt_ok() and req.get("backend") != "torch":
        ref = to_wav(req.get("ref_audio") or SAMPLE)
        rt = (req.get("ref_text") or "").strip() or ("" if req.get("ref_audio") else SAMPLE_TEXT)
        return do_tts_qt(text, ref, rt, req.get("language"))
    m = load_tts()
    ref = to_wav(req.get("ref_audio") or SAMPLE)
    ref_text = (req.get("ref_text") or "").strip()
    key = (ref, ref_text)
    if key not in st["prompts"]:
        st["progress"] = "разбор образца голоса"
        st["prompts"][key] = m.create_voice_clone_prompt(ref_audio=ref, ref_text=ref_text or None,
                                                         x_vector_only_mode=not ref_text)
    st["progress"] = "синтез"
    t = time.time()
    wavs, sr = m.generate_voice_clone(text=text, language=req.get("language") or "Auto",
                                      voice_clone_prompt=st["prompts"][key], max_new_tokens=max_new(text))
    dt = time.time() - t
    import soundfile as sf
    fn = OUT + "/tts_%s.wav" % time.strftime("%Y%m%d_%H%M%S")
    sf.write(fn, wavs[0], sr)
    return fn, {"X-Gen-Sec": "%.2f" % dt, "X-Audio-Sec": "%.2f" % (len(wavs[0]) / sr), "X-Backend": "PyTorch fp32"}


_sd_flags = None


def sd_flags():
    # флаги экономии памяти (телефон: ~3 ГБ свободно) - только те, что знает собранный sd-cli
    global _sd_flags
    if _sd_flags is None:
        try:
            h = subprocess.run([SD, "--help"], capture_output=True, text=True, errors="replace").stdout
        except Exception:
            h = ""
        _sd_flags = [f for f in ("--mmap", "--vae-tiling", "--diffusion-fa") if f in h]
        log("флаги sd-cli:", _sd_flags)
    return _sd_flags


def do_image(req):
    prompt = (req.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("пустой запрос")
    unload_tts()
    w = max(256, min(1024, int(req.get("w", 512)) // 64 * 64))
    h = max(256, min(1024, int(req.get("h", 512)) // 64 * 64))
    steps = max(1, min(30, int(req.get("steps", 4))))
    seed = int(req.get("seed", -1))
    fn = OUT + "/flux_%s.png" % time.strftime("%Y%m%d_%H%M%S")
    # необязательная настройка без пересборки: /sdcard/models/flux2/sd.json
    # {"cpus": "4-7", "threads": 4, "mmap": true, "args": []}
    try:
        with open(M + "/flux2/sd.json") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    flags = [f for f in sd_flags() if f != "--mmap" or cfg.get("mmap", True)]
    cmd = ["taskset", "-c", str(cfg.get("cpus", "4-7")), SD, "--diffusion-model", FLUX[0], "--vae", FLUX[1],
           "--llm", FLUX[2], "-p", prompt, "--cfg-scale", "1.0", "--steps", str(steps), "-W", str(w), "-H", str(h),
           "-t", str(cfg.get("threads", 4)), "-s", str(seed), "-o", fn] + flags + [str(a) for a in cfg.get("args", [])]
    log("sd-cli: ядра", cmd[2], "флаги", flags, "настройка", cfg)
    t = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    tail = []
    for line in p.stdout:
        line = line.strip()
        if line:
            st["progress"] = line[-160:]
            tail = (tail + [line])[-15:]
    rc = p.wait()
    if rc != 0 or not os.path.exists(fn):
        raise RuntimeError("sd-cli код %d:\n%s" % (rc, "\n".join(tail)))
    return fn, {"X-Gen-Sec": "%.1f" % (time.time() - t)}


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json", hdr=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (hdr or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/health"):
            self._send(200, json.dumps({"ok": True, "tts_loaded": st["tts"] is not None, "qwentts": qt_ok(), "busy": st["busy"],
                                        "progress": st["progress"]}, ensure_ascii=False))
        else:
            self._send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, '{"error":"bad json"}')
        if self.path == "/unload":
            with work:
                unload_tts()
            return self._send(200, '{"ok":true}')
        job = {"/tts": (do_tts, "audio/wav"), "/image": (do_image, "image/png")}.get(self.path)
        if not job:
            return self._send(404, "{}")
        if not work.acquire(blocking=False):
            return self._send(409, "занято: " + st["busy"], "text/plain; charset=utf-8")
        try:
            st["busy"] = self.path[1:]
            log("запрос", self.path, json.dumps(req, ensure_ascii=False)[:300])
            path, hdr = job[0](req)
            hdr["X-File"] = path
            with open(path, "rb") as f:
                data = f.read()
            self._send(200, data, job[1], hdr)
            log("готово", path, hdr)
        except Exception as e:
            log(traceback.format_exc())
            self._send(500, "%s: %s" % (type(e).__name__, e), "text/plain; charset=utf-8")
        finally:
            st["busy"] = ""
            st["progress"] = ""
            work.release()


if __name__ == "__main__":
    log("сервер 127.0.0.1:8082")
    ThreadingHTTPServer(("127.0.0.1", 8082), H).serve_forever()
