#!/usr/bin/env python3
# Fold2 AI: сервер в Debian на 127.0.0.1:8082 - клон голоса (Qwen3-TTS 0.6B Base) и картинки (FLUX.2 klein 4B,
# stable-diffusion.cpp). Голос: qwentts.cpp (GGML, Q8_0, в разы быстрее) если собран, иначе PyTorch (fp32, медленно).
import gc, json, os, re, signal, subprocess, sys, threading, time, traceback, wave
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

VER = 11  # приложение сверяет с /health и перезапускает старый сервер
M = "/sdcard/models"; OUT = M + "/out"
TTS_DIR = M + "/qwen3-tts-0.6b-base"
# sd-cli c CPU repack (npu/patch_sdcpp.py, релиз sdnpu-N): веса Q4_0 перепаковываются под NEON dotprod - в ~4 раза
# быстрее обычной сборки; если её нет - обычная сборка из исходников
SD = next((p for p in ("/opt/sdcpu/bin/sd-cli", "/opt/stable-diffusion.cpp/build/bin/sd-cli") if os.path.exists(p)),
          "/opt/stable-diffusion.cpp/build/bin/sd-cli")
FLUX = [M + "/flux2/flux-2-klein-4b-Q4_0.gguf", M + "/flux2/flux2-vae.safetensors", M + "/flux2/Qwen3-4B-Q4_0.gguf"]
SAMPLE = OUT + "/ref_clone.wav"
SAMPLE_TEXT = ("Okay. Yeah. I resent you. I love you. I respect you. But you know what? You blew it! "
               "And thanks to you.")
QT = "/opt/qwentts.cpp/build/qwen-tts"
QTM = [M + "/qwentts/qwen-talker-0.6b-base-Q8_0.gguf", M + "/qwentts/qwen-tokenizer-12hz-Q8_0.gguf"]
QT_CFG = M + "/qwentts/qt.json"  # необязательно: {"cpus": "4-7", "threads": 4, "ref_seed": 144, "ref_seed_fast": 72, "dac_gpu": true, "args": []}
# DAC (последняя часть кодека, ~95% его вычислений) на GPU Adreno: dacgpu (npu/dacgpu, работает в Android, вне chroot)
# слушает 127.0.0.1:8083; qwen-tts c QT_DAC_EXT (патч fold2) пишет вход DAC в файл и сам DAC не считает
DAC_PORT = 8083
DAC_ROOT = "/data/local/fold2/debian"  # корень chroot снаружи - пути для dacgpu
DAC_LAT = "/tmp/f2_dac.lat"


def dac_req(line, timeout=120):
    import socket
    with socket.create_connection(("127.0.0.1", DAC_PORT), timeout=timeout) as c:
        c.sendall((line + "\n").encode())
        return c.makefile().readline().strip()


def dac_ok():
    try:
        return dac_req("ping", 0.5).startswith("ok")
    except Exception:
        return False


def android_path(p):
    p = os.path.abspath(p)
    return "/data/media/0" + p[len("/sdcard"):] if p.startswith("/sdcard/") else DAC_ROOT + p


def qt_cfg():
    try:
        with open(QT_CFG) as f:
            return json.load(f)
    except Exception:
        return {}
os.makedirs(OUT, exist_ok=True)
work = threading.Lock()
st = {"tts": None, "prompts": {}, "progress": "", "busy": "", "proc": None, "cancel": False, "t0": 0, "eta": None}


class Cancelled(Exception):
    pass


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def mem_mb():
    try:
        with open("/proc/meminfo") as f:
            for l in f:
                if l.startswith("MemAvailable:"):
                    return int(l.split()[1]) // 1024
    except Exception:
        pass
    return 0


ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def run_proc(cmd, on_line=None, stdin_text=None, env=None):
    """Запуск sd-cli / qwen-tts с разбором вывода; /cancel убивает процесс (st["proc"]).
    Вывод читается сырыми кусками и режется по \\r и \\n сами: полоса прогресса sd-cli идёт через \\r без
    перевода строки, построчное чтение показывало бы её на шаг позже."""
    if st["cancel"]:
        raise Cancelled()
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    st["proc"] = p
    tail = []

    def handle(raw, partial=False):
        line = ANSI.sub("", raw.decode("utf-8", "replace")).strip()
        if not line:
            return
        if not partial:
            tail.append(line)
            del tail[:-15]
        if on_line:
            on_line(line)
        elif not partial:
            st["progress"] = line[-160:]

    try:
        if stdin_text is not None:
            p.stdin.write(stdin_text.encode())
            p.stdin.close()
        fd, buf = p.stdout.fileno(), b""
        while True:
            ch = os.read(fd, 65536)
            if not ch:
                break
            parts = re.split(rb"[\r\n]", buf + ch)
            buf = parts.pop()
            for raw in parts:
                handle(raw)
            if len(buf) > 8192:
                handle(buf)
                buf = b""
            elif buf:
                handle(buf, True)  # недописанная строка (полоса прогресса) - только для показа
        handle(buf)
        rc = p.wait()
    finally:
        st["proc"] = None
    if st["cancel"]:
        raise Cancelled()
    return rc, tail


def kill_proc():
    p = st["proc"]
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(3)
        except Exception:
            p.kill()


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


def do_tts_qt(text, ref, ref_text, lang, fast=False):
    unload_tts()
    fn = OUT + "/tts_%s.wav" % time.strftime("%Y%m%d_%H%M%S")
    cfg = qt_cfg()
    cmd = ["taskset", "-c", str(cfg.get("cpus", "4-7")), QT, "--model", QTM[0], "--codec", QTM[1],
           "--lang", qt_lang(lang, text), "--ref-wav", ref, "--max-new", str(max_new(text))] + \
        [str(a) for a in cfg.get("args", [])] + ["-o", fn]
    if ref_text:
        with open("/tmp/ref_text.txt", "w") as f:
            f.write(ref_text + "\n")
        cmd[-2:-2] = ["--ref-text", "/tmp/ref_text.txt"]
    # QT_THREADS / QT_REF_SEED / QT_DAC_MARGIN - патч fold2 в qwentts.cpp (linux/phone/qwentts_fold2.sh): потоки и
    # сколько кадров образца идут затравкой перед клоном. С обрезкой DAC (QT_DAC_MARGIN, по умолчанию 8) затравка
    # почти бесплатна: 144 кадра (как в оригинале) стоят ~0,7 с сверх 72, поэтому по умолчанию 144
    env = dict(os.environ, QT_THREADS=str(cfg.get("threads", 4)))
    seed = int(cfg.get("ref_seed_fast", 72) if fast else cfg.get("ref_seed", 144)) if ref_text else 0
    if ref_text:
        env["QT_REF_SEED"] = str(seed)
    gpu = bool(cfg.get("dac_gpu", True)) and dac_ok()
    if gpu:
        env["QT_DAC_EXT"] = DAC_LAT
        try:
            os.remove(DAC_LAT)
        except OSError:
            pass
        # модели DAC грузим на GPU заранее, пока qwen-tts генерирует (~1-2 с)
        threading.Thread(target=lambda: dac_req("load", 60), daemon=True).start()
    cps = float(cfg.get("codec_sec_per_frame", 0.3))  # CPU: секунд на кадр 12,5 Гц (DAC обрезан до кадров речи + 8)

    def on_line(line):
        m = re.search(r"Generated (\d+) frames", line)
        if m:
            st["progress"] = "генерация: %.1f с звука" % (int(m.group(1)) / 12.5)
            return
        m = re.search(r"Generation done : (\d+) frames", line)
        if m:
            n = int(m.group(1))
            st["progress"] = "декодирую звук (%.1f с)%s…" % (n / 12.5, " на GPU" if gpu else "")
            st["eta"] = 1 + n * 0.06 if gpu else (n + min(seed, 8)) * cps
        elif "Admit slot" in line:
            m = re.search(r"prefill=([\d.]+) ms", line)
            st["progress"] = "образец разобран%s, генерирую…" % (" за %.0f с" % (float(m.group(1)) / 1000) if m else "")
        elif "ref_codes" in line or "Codec encoder" in line:
            st["progress"] = "разбираю образец голоса…"
        elif st["progress"] == "запуск qwentts.cpp" or st["progress"].startswith("загрузка"):
            st["progress"] = "загрузка: " + line[-100:]

    st["progress"] = "запуск qwentts.cpp"
    t = time.time()
    rc, tail = run_proc(cmd, on_line, stdin_text=text + "\n", env=env)
    backend = "qwentts.cpp Q8_0"
    if rc == 0 and gpu and os.path.exists(DAC_LAT):
        st["progress"] = "декодирую звук на GPU…"
        try:
            r = dac_req(android_path(DAC_LAT) + "\t" + android_path(fn))
        except Exception as e:
            r = "err %s" % e
        log("dacgpu:", r)
        if r.startswith("ok"):
            backend += " + DAC на GPU"
        else:  # запасной путь: тот же синтез, DAC на CPU
            st["progress"] = "GPU не справился, повтор на CPU…"
            env.pop("QT_DAC_EXT", None)
            rc, tail = run_proc(cmd, on_line, stdin_text=text + "\n", env=env)
    try:
        os.remove(DAC_LAT)
    except OSError:
        pass
    dt = time.time() - t
    if rc != 0 or not os.path.exists(fn):
        raise RuntimeError("qwen-tts код %d:\n%s" % (rc, "\n".join(tail)))
    log("qwen-tts:", " | ".join(tail[-4:]))
    return fn, {"X-Gen-Sec": "%.2f" % dt, "X-Audio-Sec": "%.2f" % wav_sec(fn), "X-Backend": backend}


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
        return do_tts_qt(text, ref, rt, req.get("language"), bool(req.get("fast")))
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


def num(v, d):
    try:
        return int(float(v))
    except Exception:
        return d


# stdbuf (coreutils): вывод sd-cli без буфера - прогресс шагов виден сразу, а не в конце
UNBUF = ["stdbuf", "-o0", "-e0"] if os.access("/usr/bin/stdbuf", os.X_OK) else []
RE_STEP = re.compile(r"(\d+)/(\d+) - +([\d.]+)(s/it|it/s)")  # sd.cpp: "%*i/%i - %10s" - скорость с отступом
RE_TAKE = re.compile(r"([\w ]+?) completed(?: in|, taking) ([\d.]+)s")


def do_image(req):
    prompt = (req.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("пустой запрос")
    unload_tts()
    w = max(256, min(1024, num(req.get("w"), 512) // 64 * 64))
    h = max(256, min(1024, num(req.get("h"), 512) // 64 * 64))
    steps = max(1, min(30, num(req.get("steps"), 4)))
    seed = num(req.get("seed"), -1)
    if seed < 0:  # свой случайный seed - чтобы показать его и дать повторить картинку
        seed = int.from_bytes(os.urandom(4), "little") & 0x7fffffff
    fn = OUT + "/flux_%s.png" % time.strftime("%Y%m%d_%H%M%S")
    # необязательная настройка без пересборки: /sdcard/models/flux2/sd.json
    # {"cpus": "4-7", "threads": 4, "mmap": true, "args": []}
    try:
        with open(M + "/flux2/sd.json") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    flags = [f for f in sd_flags() if f != "--mmap" or cfg.get("mmap", True)]
    cmd = ["taskset", "-c", str(cfg.get("cpus", "4-7"))] + UNBUF + [SD, "--diffusion-model", FLUX[0], "--vae", FLUX[1],
           "--llm", FLUX[2], "-p", prompt, "--cfg-scale", "1.0", "--steps", str(steps), "-W", str(w), "-H", str(h),
           "-t", str(cfg.get("threads", 4)), "-s", str(seed), "-o", fn] + flags + [str(a) for a in cfg.get("args", [])]
    log("sd-cli: ядра", cmd[2], "флаги", flags, "настройка", cfg)
    vae = 13.0 * w * h / 65536  # декодер VAE (tiling): ~13 с на 256x256 (замер sdnpu-2)
    ph = {"name": "загрузка моделей и кодирование текста", "sampling": False}

    def on_line(line):
        m = RE_STEP.search(line)
        if m and ph["sampling"] and int(m.group(2)) == steps:
            i, n, v = int(m.group(1)), int(m.group(2)), float(m.group(3))
            spi = v if m.group(4) == "s/it" else (1.0 / v if v else 0)
            if i == 0 or spi <= 0:
                return
            st["eta"] = (n - i) * spi + vae
            st["progress"] = "шаг %d/%d · %.0f с/шаг" % (i, n, spi)
            return
        m = RE_TAKE.search(line)
        if m:
            what = m.group(1).strip()
            if "learned_condition" in what:
                ph["sampling"] = True
                st["eta"] = None
                st["progress"] = "текст закодирован за %s с, рисую…" % m.group(2)
            elif "sampling" in what:
                ph["sampling"] = False
                st["eta"] = vae
                st["progress"] = "шаги готовы, декодирую VAE…"
            return
        if "sampling using" in line or "generating image" in line:
            ph["sampling"] = True
        if not ph["sampling"] and not st["eta"]:
            st["progress"] = ph["name"]

    st["progress"] = ph["name"]
    t = time.time()
    rc, tail = run_proc(cmd, on_line)
    if rc != 0 or not os.path.exists(fn):
        raise RuntimeError("sd-cli код %d:\n%s" % (rc, "\n".join(tail)))
    return fn, {"X-Gen-Sec": "%.1f" % (time.time() - t), "X-Seed": str(seed), "X-Size": "%dx%d" % (w, h)}


CT = {".png": "image/png", ".wav": "audio/wav", ".jpg": "image/jpeg", ".mp3": "audio/mpeg"}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype="application/json", hdr=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "*")
        for k, v in (hdr or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, *a):
        pass

    def _file(self, name):
        # готовые картинки/звук прямо по http (без base64 через мост): /out/<имя>, поддержка Range для <audio>
        if not re.fullmatch(r"[\w.-]+", name) or name.startswith("."):
            return self._send(400, "{}")
        fn = os.path.join(OUT, name)
        if not os.path.isfile(fn):
            return self._send(404, "{}")
        size = os.path.getsize(fn)
        a, b, code = 0, size - 1, 200
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if m and size:
            if m.group(1):
                a = int(m.group(1))
                b = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            elif m.group(2):
                a = max(0, size - int(m.group(2)))
            code = 206
        with open(fn, "rb") as f:
            f.seek(a)
            data = f.read(max(0, b - a + 1))
        hdr = {"Accept-Ranges": "bytes", "Cache-Control": "max-age=86400"}
        if code == 206:
            hdr["Content-Range"] = "bytes %d-%d/%d" % (a, a + len(data) - 1, size)
        self._send(code, data, CT.get(os.path.splitext(fn)[1].lower(), "application/octet-stream"), hdr)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path.startswith("/health"):
            el = time.time() - st["t0"] if st["busy"] else 0
            self._send(200, json.dumps({"ok": True, "ver": VER, "tts_loaded": st["tts"] is not None, "qwentts": qt_ok(),
                                        "busy": st["busy"], "progress": st["progress"], "elapsed": round(el),
                                        "eta": None if st["eta"] is None else round(st["eta"]), "mem": mem_mb(),
                                        "sd": SD}, ensure_ascii=False))
        elif self.path.startswith("/out/"):
            self._file(self.path[5:].split("?")[0])
        elif self.path.startswith("/list"):
            try:
                fs = sorted((e for e in os.scandir(OUT) if e.is_file() and e.name.startswith(("flux_", "tts_"))),
                            key=lambda e: e.stat().st_mtime, reverse=True)[:40]
                out = [{"name": e.name, "size": e.stat().st_size, "t": int(e.stat().st_mtime)} for e in fs]
            except Exception:
                out = []
            self._send(200, json.dumps(out))
        else:
            self._send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, '{"error":"bad json"}')
        if self.path == "/cancel":
            if st["busy"]:
                st["cancel"] = True
                st["progress"] = "отмена…"
                kill_proc()
            return self._send(200, '{"ok":true}')
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
            st.update(busy=self.path[1:], cancel=False, t0=time.time(), eta=None, progress="")
            log("запрос", self.path, json.dumps(req, ensure_ascii=False)[:300])
            path, hdr = job[0](req)
            hdr["X-File"] = path
            log("готово", path, hdr)
            if req.get("ret") == "json":  # приложение 8+: только имя файла, сам файл - GET /out/<имя>
                hdr["name"] = os.path.basename(path)
                self._send(200, json.dumps(hdr, ensure_ascii=False))
            else:
                with open(path, "rb") as f:
                    self._send(200, f.read(), job[1], hdr)
        except Cancelled:
            log("отменено")
            self._send(499, "отменено", "text/plain; charset=utf-8")
        except Exception as e:
            log(traceback.format_exc())
            self._send(500, "%s: %s" % (type(e).__name__, e), "text/plain; charset=utf-8")
        finally:
            st.update(busy="", progress="", cancel=False, eta=None)
            work.release()


def bye(*a):
    kill_proc()  # не оставлять sd-cli / qwen-tts работать после остановки сервера
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGHUP, bye)
    log("сервер 127.0.0.1:8082, версия", VER, "sd-cli", SD)
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("127.0.0.1", 8082), H).serve_forever()
