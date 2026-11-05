#!/usr/bin/env python3
# Fold2 AI: сервер в Debian на 127.0.0.1:8082 - клон голоса (Qwen3-TTS 0.6B Base) и картинки (FLUX.2 klein 4B,
# stable-diffusion.cpp). Голос: qwentts.cpp (GGML, Q8_0, в разы быстрее) если собран, иначе PyTorch (fp32, медленно).
import base64, gc, hashlib, json, os, queue, re, shutil, signal, subprocess, sys, threading, time, traceback, wave
import urllib.error, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

VER = 15  # приложение сверяет с /health и перезапускает старый сервер
M = "/sdcard/models"; OUT = M + "/out"
TTS_DIR = M + "/qwen3-tts-0.6b-base"
# sd-cli c CPU repack (npu/patch_sdcpp.py, релиз sdnpu-N): веса Q4_0 перепаковываются под NEON dotprod - в ~4 раза
# быстрее обычной сборки; если её нет - обычная сборка из исходников
SD = next((p for p in ("/opt/sdcpu/bin/sd-cli", "/opt/stable-diffusion.cpp/build/bin/sd-cli") if os.path.exists(p)),
          "/opt/stable-diffusion.cpp/build/bin/sd-cli")
FLUX = [M + "/flux2/flux-2-klein-4b-Q4_0.gguf", M + "/flux2/flux2-vae.safetensors", M + "/flux2/Qwen3-4B-Q4_0.gguf"]
# TAEF2 (madebyollin, 10 МБ) - крошечный декодер латентов FLUX.2: секунды вместо ~минуты полного VAE на 512x512
# (sd.cpp 58bb3c1 понимает его через --taesd); им же - превью картинки на каждом шаге
TAEF2 = M + "/flux2/taef2.safetensors"
PREV = OUT + "/prev_flux.png"
SAMPLE = OUT + "/ref_clone.wav"
SAMPLE_TEXT = ("Okay. Yeah. I resent you. I love you. I respect you. But you know what? You blew it! "
               "And thanks to you.")
QT = "/opt/qwentts.cpp/build/qwen-tts"
QTM = [M + "/qwentts/qwen-talker-0.6b-base-Q8_0.gguf", M + "/qwentts/qwen-tokenizer-12hz-Q8_0.gguf"]
QT_CFG = M + "/qwentts/qt.json"  # необязательно: {"cpus": "4-6", "threads": 3, "boost": true, "ref_seed": 144, "ref_seed_fast": 72, "dac_gpu": true, "args": []}
# DAC (последняя часть кодека, ~95% его вычислений) на GPU Adreno: dacgpu (npu/dacgpu, работает в Android, вне chroot)
# слушает 127.0.0.1:8083; qwen-tts c QT_DAC_EXT (патч fold2) пишет вход DAC в файл и сам DAC не считает
DAC_PORT = 8083
DAC_ROOT = "/data/local/fold2/debian"  # корень chroot снаружи - пути для dacgpu
DAC_LAT = "/tmp/f2_dac.lat"
# tts-server (qwentts.cpp): модели остаются в памяти между запросами, голоса регистрируются один раз из кэша
# .spk/.rvq (qwen-codec, бит-в-бит как разбор --ref-wav внутри qwen-tts) - без загрузки (~4 с) и разбора образца (~6 с)
QTS = "/opt/qwentts.cpp/build/tts-server"; QTC = "/opt/qwentts.cpp/build/qwen-codec"; QTS_PORT = 8084
VOICES = M + "/qwentts/voices"  # кэш голосов: <md5 wav>.spk / .rvq
QTD = M + "/qwentts"
SAVED = QTD + "/saved"  # сохранённые голоса: <имя>.wav + <имя>.txt (текст образца)
HF_QT = "https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main/"
HF_VL = "https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct-GGUF/resolve/main/"
# готовые голоса CustomVoice (описания - README QwenLM/Qwen3-TTS); говорят на любом из 10 языков, родной - в скобках
SPEAKERS = {"vivian": "Вивиан - яркий, чуть дерзкий молодой женский (кит.)",
            "serena": "Серена - тёплый, мягкий молодой женский (кит.)",
            "uncle_fu": "Дядя Фу - зрелый мужской, низкий бархатный (кит.)",
            "dylan": "Дилан - молодой мужской, пекинский говор (кит.)",
            "eric": "Эрик - живой мужской с хрипотцой, сычуаньский (кит.)",
            "ryan": "Райан - энергичный мужской, сильный ритм (англ.)",
            "aiden": "Эйден - солнечный американский мужской (англ.)",
            "ono_anna": "Оно Анна - игривый лёгкий женский (япон.)",
            "sohee": "Сохи - тёплый эмоциональный женский (кор.)"}
KIND = {"clone": "base", "speaker": "customvoice", "design": "voicedesign"}
QUANTS = ("Q8_0", "Q4_K_M", "BF16", "F32")
VNAME = r"[\w а-яА-ЯёЁ.-]{1,40}"
DL = {}  # разрешённые загрузки: имя файла -> (папка, URL)
for _m in ("0.6b-customvoice-Q8_0", "1.7b-customvoice-Q8_0", "1.7b-customvoice-Q4_K_M", "1.7b-voicedesign-Q8_0",
           "1.7b-voicedesign-Q4_K_M", "1.7b-base-Q8_0", "1.7b-base-Q4_K_M"):
    DL["qwen-talker-%s.gguf" % _m] = (QTD, HF_QT + "qwen-talker-%s.gguf" % _m)
for _f in ("Qwen3VL-2B-Instruct-Q4_K_M.gguf", "mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf"):
    DL[_f] = (M, HF_VL + _f)
DL["taef2.safetensors"] = (M + "/flux2", "https://huggingface.co/madebyollin/taef2/resolve/main/taef2.safetensors")
dl = {"file": "", "got": 0, "total": 0, "err": "", "busy": False, "stop": False}
qs = {"proc": None, "sig": None, "voices": set(), "last": 0.0, "on_line": None, "tail": [], "busy": False}


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
# Ускорение без изменения результата: на время синтеза минимальные частоты шины памяти / L3 / LLCC (devfreq) = максимум.
# Генерация упирается в память (веса читаются на каждый кадр); после синтеза - прежние значения. Сбережённые значения
# лежат в файле, чтобы вернуть их и после падения сервера.
BOOST_SAVED = "/tmp/f2_devfreq_saved.json"
DEVFREQ = "/sys/class/devfreq"


def boost_targets(gpu):
    out = []
    try:
        names = sorted(os.listdir(DEVFREQ))
    except OSError:
        return out
    for n in names:
        if re.search(r"cpu.*(l3|llcc|ddr)", n) and "cdsp" not in n:
            out.append(n)
        elif gpu and (n.endswith("kgsl-3d0") or n.endswith("gpubw")):
            out.append(n)
    return out


def boost_restore():
    try:
        with open(BOOST_SAVED) as f:
            saved = json.load(f)
    except Exception:
        return
    for n, v in saved.items():
        try:
            with open(os.path.join(DEVFREQ, n, "min_freq"), "w") as f:
                f.write(str(v))
        except OSError:
            pass
    try:
        os.remove(BOOST_SAVED)
    except OSError:
        pass


def boost_on(cfg, gpu):
    if not cfg.get("boost", True):
        return
    boost_restore()
    saved = {}
    for n in boost_targets(gpu and cfg.get("boost_gpu", False)):  # GPU (DAC) и так на максимуме - без пользы
        d = os.path.join(DEVFREQ, n)
        try:
            with open(d + "/min_freq") as f:
                v = f.read().strip()
            with open(d + "/max_freq") as f:
                mx = f.read().strip()
            saved[n] = v
            with open(d + "/min_freq", "w") as f:
                f.write(mx)
        except OSError:
            pass
    if saved:
        with open(BOOST_SAVED, "w") as f:
            json.dump(saved, f)


work = threading.Lock()
st = {"tts": None, "prompts": {}, "progress": "", "busy": "", "proc": None, "cancel": False, "t0": 0, "eta": None,
      "parts": [], "nparts": 0, "seed": None}


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
    if qs["busy"]:  # отмена посреди запроса к tts-server: проще всего снять его, модели загрузятся при следующем
        qs_stop()
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
    # qwen-tts собран и есть кодек; сами модели (Base / CustomVoice / VoiceDesign) выбирает qt_pick
    return os.access(QT, os.X_OK) and os.path.exists(QTM[1])


def qt_models():
    """{"0.6b-base": ["Q8_0"], "1.7b-customvoice": ["Q4_K_M"], ...} - что лежит в /sdcard/models/qwentts"""
    res = {}
    try:
        names = os.listdir(QTD)
    except OSError:
        names = []
    for f in names:
        m = re.fullmatch(r"qwen-talker-(0\.6b|1\.7b)-(base|customvoice|voicedesign)-(\w+)\.gguf", f)
        if m:
            res.setdefault(m.group(1) + "-" + m.group(2), []).append(m.group(3))
    return res


def qt_pick(kind, size="", big=False, quant=""):
    """(путь, размер, квантование) модели нужного типа или None. big - сначала 1.7B (интонации / дизайн голоса)"""
    ms = qt_models()
    sizes = [size] if size in ("0.6b", "1.7b") else (["1.7b", "0.6b"] if big else ["0.6b", "1.7b"])
    for s in sizes:
        have = ms.get(s + "-" + kind) or []
        for q in ([quant] if quant else []) + list(QUANTS):
            if q in have:
                return "%s/qwen-talker-%s-%s-%s.gguf" % (QTD, s, kind, q), s, q
    return None


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


def split_text(text, first=110, rest=220):
    """Фразы для конвейера: первая короче (быстрее зазвучит), дальше до ~15 с речи (влезает в один кусок кодека,
    значит DAC идёт на GPU). Режем по концам предложений, слишком длинные - по запятым."""
    pieces = []
    for s in re.split(r"(?<=[.!?…;:])\s+|\n+", text.strip()):
        s = s.strip()
        while len(s) > rest * 1.4:
            cut = max(s.rfind(c, 0, rest) for c in (",", "—", "–", " "))
            cut = cut if cut > rest // 3 else rest
            pieces.append(s[:cut + 1].strip())
            s = s[cut + 1:].strip()
        if s:
            pieces.append(s)
    chunks, cur = [], ""
    for p in pieces:
        lim = first if not chunks else rest
        if cur and len(cur) + 1 + len(p) > lim:
            chunks.append(cur)
            cur = p
        else:
            cur = (cur + " " + p).strip()
    if cur:
        chunks.append(cur)
    if len(chunks) > 1 and len(chunks[-1]) < 25:  # огрызок в конце - к предыдущей фразе
        chunks[-2] += " " + chunks.pop()
    return chunks or [text]


def qs_http(path, body=None, timeout=30):
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    rq = urllib.request.Request("http://127.0.0.1:%d%s" % (QTS_PORT, path), data=data,
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(rq, timeout=timeout) as f:
            return f.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError("tts-server %s: %d %s" % (path, e.code, e.read()[:300].decode("utf-8", "replace")))


def qs_ok(cfg):
    return cfg.get("server", True) and os.access(QTS, os.X_OK) and os.access(QTC, os.X_OK)


def qs_alive():
    p = qs["proc"]
    return p is not None and p.poll() is None


def qs_stop():
    p = qs["proc"]
    qs.update(proc=None, sig=None, voices=set())
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(5)
        except Exception:
            p.kill()
        log("tts-server остановлен")


def qs_reader(p):
    for raw in iter(p.stdout.readline, b""):
        line = ANSI.sub("", raw.decode("utf-8", "replace")).strip()
        if not line:
            continue
        qs["tail"].append(line)
        del qs["tail"][:-30]
        cb = qs["on_line"]
        if cb:
            try:
                cb(line)
            except Exception:
                pass


def qs_start(env, cpus, model):
    sig = (cpus, model) + tuple(env.get(k) for k in ("QT_THREADS", "QT_REF_SEED", "QT_DAC_EXT", "QT_DAC_MARGIN", "QT_REPACK"))
    if qs_alive() and qs["sig"] == sig:
        return
    qs_stop()
    st["progress"] = "загрузка модели %s…" % os.path.basename(model)
    t = time.time()
    p = subprocess.Popen(["taskset", "-c", cpus, QTS, "--model", model, "--codec", QTM[1], "--host", "127.0.0.1",
                          "--port", str(QTS_PORT)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, env=env)
    qs.update(proc=p, sig=sig, voices=set(), tail=[])
    threading.Thread(target=qs_reader, args=(p,), daemon=True).start()
    while time.time() - t < 180:
        if p.poll() is not None:
            qs_stop()
            raise RuntimeError("tts-server завершился: " + " | ".join(qs["tail"][-5:]))
        if st["cancel"]:
            qs_stop()
            raise Cancelled()
        try:
            qs_http("/v1/models", None, 2)
            log("tts-server готов за %.1f с:" % (time.time() - t), os.path.basename(model))
            return
        except Exception:
            time.sleep(0.2)
    qs_stop()
    raise RuntimeError("tts-server не ответил за 180 с")


def qs_voice(ref, ref_text, cpus, threads, model, size):
    with open(ref, "rb") as f:
        h = hashlib.md5(f.read()).hexdigest()[:16]
    name = "v%s_%s" % (h, hashlib.md5(ref_text.encode()).hexdigest()[:8])
    if name in qs["voices"]:
        return name
    base = os.path.join(VOICES, h if size == "0.6b" else h + "_" + size)  # x-vector у 0.6B и 1.7B разный
    if not (os.path.exists(base + ".spk") and os.path.exists(base + ".rvq")):
        os.makedirs(VOICES, exist_ok=True)
        shutil.copyfile(ref, base + ".wav")
        st["progress"] = "разбираю образец голоса (один раз для этого образца)…"
        rc, tail = run_proc(["taskset", "-c", cpus, QTC, "--model", QTM[1], "--talker", model, "-i", base + ".wav"],
                            lambda l: None, env=dict(os.environ, QT_THREADS=threads))
        os.remove(base + ".wav")
        if rc != 0 or not (os.path.exists(base + ".spk") and os.path.exists(base + ".rvq")):
            raise RuntimeError("qwen-codec код %d: %s" % (rc, " | ".join(tail[-4:])))
    with open(base + ".spk", "rb") as f:
        spk = base64.b64encode(f.read()).decode()
    with open(base + ".rvq", "rb") as f:
        rvq = base64.b64encode(f.read()).decode()
    qs_http("/v1/audio/voices", {"name": name, "ref_text": ref_text, "spk_b64": spk, "rvq_b64": rvq}, 120)
    qs["voices"].add(name)
    return name


def qs_idle():
    # модели и буферы tts-server (до ~4 ГБ) держим, пока голос нужен: после server_idle секунд без запросов - выгрузка
    while True:
        time.sleep(20)
        if qs_alive() and time.time() - qs["last"] > float(qt_cfg().get("server_idle", 300)) and \
                work.acquire(blocking=False):
            try:
                if qs_alive() and time.time() - qs["last"] > float(qt_cfg().get("server_idle", 300)):
                    log("tts-server: простой, выгружаю")
                    qs_stop()
            finally:
                work.release()


# Параметры выборки tts-server (поля OpenAI-запроса) и те же флаги qwen-tts; значения ограничиваются диапазоном
SAMP = {"temperature": (float, 0.0, 2.0, "--temp"), "top_k": (int, 0, 500, "--top-k"), "top_p": (float, 0.01, 1.0, "--top-p"),
        "repetition_penalty": (float, 0.5, 3.0, "--rep-pen"), "subtalker_temperature": (float, 0.0, 2.0, "--sub-temp"),
        "subtalker_top_k": (int, 0, 500, "--sub-top-k"), "subtalker_top_p": (float, 0.01, 1.0, "--sub-top-p")}
MISSING = {"base": "нет модели клона голоса (qwen-talker-*-base)",
           "customvoice": "нет модели готовых голосов - Голос → Модели → «Готовые голоса»",
           "voicedesign": "нет модели дизайна голоса - Голос → Модели → «Дизайн голоса 1.7B»"}


def sampling(req):
    out = {}
    for k, (t, lo, hi, _) in SAMP.items():
        v = req.get(k)
        if v is None or v == "":
            continue
        try:
            v = t(float(v))
        except (TypeError, ValueError):
            continue
        out[k] = min(hi, max(lo, v))
    return out


def post_fx(wav, tempo, pitch):
    """темп (без смены высоты) и высота тона в полутонах - ffmpeg; модель сама так не умеет (speed она игнорирует)"""
    if abs(tempo - 1) < 0.01 and abs(pitch) < 0.05:
        return True
    r = 2 ** (pitch / 12.0) if abs(pitch) >= 0.05 else 1.0
    af = ["asetrate=%d" % round(24000 * r), "aresample=24000"] if r != 1.0 else []
    t = tempo / r
    while t > 2:
        af.append("atempo=2")
        t /= 2
    while t < 0.5:
        af.append("atempo=0.5")
        t /= 0.5
    af.append("atempo=%.4f" % t)
    tmp = wav + ".fx.wav"
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-af", ",".join(af), "-ar", "24000", "-ac", "1",
                        "-c:a", "pcm_s16le", tmp], check=True, timeout=120)
        os.replace(tmp, wav)
        return True
    except Exception as e:
        log("эффекты темп/тон не применились:", e)
        return False


def wav_concat(parts, fn, gap_ms=90):
    with wave.open(parts[0]) as w0:
        prm = w0.getparams()
    sil = b"\0" * (int(prm.framerate * gap_ms / 1000) * prm.sampwidth * prm.nchannels)
    with wave.open(fn, "wb") as out:
        out.setparams(prm)
        for i, p in enumerate(parts):
            with wave.open(p) as w:
                out.writeframes(w.readframes(w.getnframes()))
            if i < len(parts) - 1:
                out.writeframes(sil)


def do_tts_qt(req, text, ref, ref_text):
    unload_tts()
    cfg = qt_cfg()
    mode = req.get("mode") if req.get("mode") in KIND else "clone"
    kind = KIND[mode]
    # инструкции (интонация, эмоция, темп, манера) понимают CustomVoice и VoiceDesign; Base (клон) их отвергает
    instruct = (req.get("instruct") or "").strip()[:600] if kind != "base" else ""
    if kind == "voicedesign" and not instruct:
        raise ValueError("опишите голос - поле «Какой голос»")
    pk = qt_pick(kind, str(req.get("size") or ""), big=kind == "voicedesign" or bool(instruct), quant=str(cfg.get("quant", "")))
    if not pk:
        raise RuntimeError(MISSING[kind])
    model, size, quant = pk
    note = ""
    if instruct and size == "0.6b":  # 0.6B CustomVoice инструкций не понимает (у Qwen интонации - только 1.7B)
        instruct, note = "", " · интонации пропущены: нужна модель 1.7B"
    speaker = ""
    if kind == "customvoice":
        speaker = str(req.get("speaker") or "vivian").lower()
        if speaker not in SPEAKERS:
            speaker = "vivian"
    if kind != "base":
        ref, ref_text = "", ""
    lang = qt_lang(req.get("language"), text)
    samp = sampling(req)
    seed = num(req.get("seed"), -1)
    if seed < 0:  # свой случайный seed - показать и дать повторить тот же дубль
        seed = int.from_bytes(os.urandom(4), "little") & 0x7fffffff
    try:
        tempo = min(2.0, max(0.5, float(req.get("tempo") or 1)))
        pitch = min(12.0, max(-12.0, float(req.get("pitch") or 0)))
    except (TypeError, ValueError):
        tempo, pitch = 1.0, 0.0
    stamp = time.strftime("%Y%m%d_%H%M%S")
    fn = OUT + "/tts_%s.wav" % stamp
    for f in os.listdir(OUT):  # куски прошлых фраз (их уже проиграли)
        if f.startswith("part_"):
            try:
                os.remove(os.path.join(OUT, f))
            except OSError:
                pass
    cpus = str(cfg.get("cpus", "4-6"))
    # 3 потока на ядрах 4-6 (Cortex-A77) быстрее 4 потоков на 4-7; результат от числа потоков не зависит (md5 тот же).
    # QT_REPACK=1: веса Q8_0 в CPU_REPACK (dotprod-ядра 4x4) - та же точность, ~30% быстрее. QT_REF_SEED - затравка клона.
    env = dict(os.environ, QT_THREADS=str(cfg.get("threads", 3)))
    env["QT_REPACK"] = "1" if cfg.get("repack", True) else "0"
    env["QT_REF_SEED"] = str(int(cfg.get("ref_seed", 144)))
    gpu = bool(cfg.get("dac_gpu", True)) and dac_ok()
    if gpu:
        # GPU уступает экрану (DeX): низкий приоритет контекстов OpenCL, куски не длиннее 128 кадров, пауза 2 мс
        dex = req.get("dex", cfg.get("dex", True))
        try:
            log("dacgpu:", dac_req("cfg prio=%s maxn=%d gap=%d" % (("low", 128, 2) if dex else ("normal", 0, 0)), 5))
        except Exception:
            pass
        env["QT_DAC_EXT"] = DAC_LAT
        threading.Thread(target=lambda: dac_req("load", 60), daemon=True).start()  # модели DAC на GPU заранее
    chunks = split_text(text) if req.get("split", cfg.get("split", True)) else [text]
    n = len(chunks)
    st.update(parts=[], nparts=n, seed=seed)
    body0 = dict({"language": lang, "response_format": "wav", "seed": seed}, **samp)
    if instruct:
        body0["instructions"] = instruct
    if kind == "base" and ref_text:
        with open("/tmp/ref_text.txt", "w") as f:
            f.write(ref_text + "\n")
    S = {"server": qs_ok(cfg), "voice": None, "backend": "", "gpu_used": 0, "gpu_busy": "", "fx": True}

    def on_line_for(i):
        pre = "фраза %d/%d: " % (i + 1, n) if n > 1 else ""

        def on_line(line):
            m = re.search(r"Generated (\d+) frames", line)
            if m:
                st["progress"] = pre + "генерация: %.1f с звука%s" % (int(m.group(1)) / 12.5, S["gpu_busy"])
                return
            if re.search(r"Generation done : (\d+) frames", line):
                st["progress"] = pre + ("готово, звук декодирует GPU" if gpu else "декодирую звук…")
            elif "Admit slot" in line:
                st["progress"] = pre + "генерирую…"
            elif "ref_codes" in line or "Codec encoder" in line:
                st["progress"] = "разбираю образец голоса…"
            elif st["progress"].startswith("загрузка"):
                st["progress"] = "загрузка: " + line[-100:]
        return on_line

    def cli(ch, wav, e2, on_line):
        cmd = ["taskset", "-c", cpus, QT, "--model", model, "--codec", QTM[1], "--lang", lang,
               "--max-new", str(max_new(ch)), "--seed", str(seed)]
        for k, v in samp.items():
            cmd += [SAMP[k][3], str(v)]
        if kind == "base":
            cmd += ["--ref-wav", ref] + (["--ref-text", "/tmp/ref_text.txt"] if ref_text else [])
        if speaker:
            cmd += ["--speaker", speaker]
        if instruct:
            cmd += ["--instruct", instruct]
        cmd += [str(a) for a in cfg.get("args", [])] + ["-o", wav]
        rc, tail = run_proc(cmd, on_line, stdin_text=ch + "\n", env=e2)
        if rc != 0 or not os.path.exists(wav):
            raise RuntimeError("qwen-tts код %d:\n%s" % (rc, "\n".join(tail)))
        S["backend"] = "qwentts.cpp %s %s" % (size, quant)

    def one(i, ch, wav, cpu_only=False):
        """фраза i -> wav; возвращает latent-файл, если звук ещё должен декодировать GPU, иначе None"""
        try:
            os.remove(DAC_LAT)
        except OSError:
            pass
        on_line = on_line_for(i)
        done = False
        if S["server"] and not cpu_only:
            try:
                qs_start(env, cpus, model)
                if kind == "base" and S["voice"] is None:
                    S["voice"] = qs_voice(ref, ref_text, cpus, env["QT_THREADS"], model, size)
                body = dict(body0, input=ch, max_new_tokens=max_new(ch))
                if S["voice"] or speaker:
                    body["voice"] = S["voice"] or speaker
                st["progress"] = ("фраза %d/%d: " % (i + 1, n) if n > 1 else "") + "генерирую…" + S["gpu_busy"]
                qs.update(on_line=on_line, busy=True)
                try:
                    data = qs_http("/v1/audio/speech", body, 1800)
                finally:
                    qs.update(on_line=None, busy=False, last=time.time())
                if st["cancel"]:
                    raise Cancelled()
                with open(wav, "wb") as f:  # с QT_DAC_EXT - тишина нужной длины, звук запишет dacgpu
                    f.write(data)
                S["backend"] = "qwentts.cpp %s %s (сервер)" % (size, quant)
                done = True
            except Cancelled:
                raise
            except Exception as e:
                if st["cancel"]:
                    raise Cancelled()
                log("tts-server не справился, запасной путь qwen-tts:", e)
                qs_stop()
                S["server"] = False
        if not done:
            e2 = dict(env)
            if cpu_only:
                e2.pop("QT_DAC_EXT", None)
            cli(ch, wav, e2, on_line)
        if gpu and not cpu_only and os.path.exists(DAC_LAT):
            lat = "/tmp/f2_dac_%d.lat" % i
            os.replace(DAC_LAT, lat)
            return lat
        return None

    ready = [None] * n
    fail = []
    jobs = queue.Queue()

    plock = threading.Lock()  # публикуют и основной поток (DAC на процессоре), и поток GPU

    def publish(i, wav):
        S["fx"] = post_fx(wav, tempo, pitch) and S["fx"]
        with plock:
            ready[i] = wav
            while len(st["parts"]) < n and ready[len(st["parts"])]:  # по порядку - приложение играет их подряд
                st["parts"].append(os.path.basename(ready[len(st["parts"])]))

    def gpu_worker():
        # пока процессор генерирует фразу i+1, GPU декодирует фразу i
        while True:
            it = jobs.get()
            if it is None:
                return
            i, lat, wav = it
            S["gpu_busy"] = " · GPU: фраза %d" % (i + 1) if n > 1 else ""
            try:
                r = dac_req(android_path(lat) + "\t" + android_path(wav))
            except Exception as e:
                r = "err %s" % e
            S["gpu_busy"] = ""
            try:
                os.remove(lat)
            except OSError:
                pass
            log("dacgpu:", r)
            if r.startswith("ok"):
                S["gpu_used"] += 1
                publish(i, wav)
            else:
                fail.append(i)

    t = time.time()
    boost_on(cfg, gpu)
    th = threading.Thread(target=gpu_worker, daemon=True)
    th.start()
    try:
        for i, ch in enumerate(chunks):
            if st["cancel"]:
                raise Cancelled()
            wav = "%s/part_%s_%02d.wav" % (OUT, stamp, i)
            lat = one(i, ch, wav)
            if lat:
                jobs.put((i, lat, wav))
            else:
                publish(i, wav)
        jobs.put(None)
        while th.is_alive():
            th.join(0.5)
            if st["cancel"]:
                raise Cancelled()
            if not S["gpu_busy"] and n > 1:
                st["progress"] = "GPU декодирует последнюю фразу…"
        for i in sorted(fail):  # GPU не справился - эта фраза заново, DAC на процессоре
            st["progress"] = "GPU не справился, фраза %d - на процессоре…" % (i + 1)
            wav = "%s/part_%s_%02d.wav" % (OUT, stamp, i)
            one(i, chunks[i], wav, cpu_only=True)
            publish(i, wav)
    finally:
        jobs.put(None)
        boost_restore()
        for i in range(n):
            try:
                os.remove("/tmp/f2_dac_%d.lat" % i)
            except OSError:
                pass
    if any(r is None for r in ready):
        raise RuntimeError("не все фразы озвучены")
    if n == 1:
        shutil.copyfile(ready[0], fn)
    else:
        wav_concat(ready, fn, int(cfg.get("gap_ms", 90)))
    dt = time.time() - t
    be = S["backend"] + (" + DAC на GPU" if S["gpu_used"] else "")
    if n > 1:
        be += " · %d фраз, процессор и GPU параллельно" % n if S["gpu_used"] else " · %d фраз" % n
    if not S["fx"]:
        be += " · без темпа/тона (нет ffmpeg?)"
    be += note
    log("qwen-tts:", " | ".join(qs["tail"][-3:]))
    return fn, {"X-Gen-Sec": "%.2f" % dt, "X-Audio-Sec": "%.2f" % wav_sec(fn), "X-Backend": be, "X-Seed": str(seed),
                "X-Model": os.path.basename(model), "X-Parts": str(n), "X-Mode": mode}


def saved_voices():
    out = []
    try:
        for f in sorted(os.listdir(SAVED)):
            if f.endswith(".wav"):
                nm = f[:-4]
                try:
                    with open(os.path.join(SAVED, nm + ".txt")) as t:
                        tx = t.read().strip()
                except OSError:
                    tx = ""
                out.append({"name": nm, "text": tx, "sec": round(wav_sec(os.path.join(SAVED, f)), 1)})
    except OSError:
        pass
    return out


def do_tts(req):
    text = (req.get("text") or "").strip()
    if not text:
        raise ValueError("пустой текст")
    mode = req.get("mode") if req.get("mode") in KIND else "clone"
    ra = req.get("ref_audio") or ""
    rt_in = (req.get("ref_text") or "").strip()
    if ra.startswith("saved:"):  # сохранённый голос: образец и его текст из /sdcard/models/qwentts/saved
        nm = ra[6:]
        if not re.fullmatch(VNAME, nm) or not os.path.exists(os.path.join(SAVED, nm + ".wav")):
            raise ValueError("нет сохранённого голоса " + nm)
        ra = os.path.join(SAVED, nm + ".wav")
        if not rt_in:
            try:
                with open(os.path.join(SAVED, nm + ".txt")) as f:
                    rt_in = f.read().strip()
            except OSError:
                pass
    if mode == "clone" and not os.path.exists(SAMPLE) and not ra:
        subprocess.run(["curl", "-fsSL", "-o", SAMPLE,
                        "https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-TTS-Repo/clone.wav"], check=True)
    if qt_ok() and req.get("backend") != "torch":
        ref = to_wav(ra or SAMPLE) if mode == "clone" else ""
        rt = rt_in or ("" if ra else SAMPLE_TEXT)
        return do_tts_qt(req, text, ref, rt)
    if mode != "clone":
        raise RuntimeError("готовые голоса и дизайн голоса работают только через qwentts.cpp - он не собран")
    m = load_tts()
    ref = to_wav(ra or SAMPLE)
    ref_text = rt_in
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


def voice_save(req):
    nm = (req.get("name") or "").strip()
    src = os.path.join(OUT, os.path.basename(req.get("file") or ""))
    if not re.fullmatch(VNAME, nm):
        raise ValueError("имя: буквы, цифры, пробел, - _ (до 40 символов)")
    if not os.path.isfile(src) or not src.endswith(".wav"):
        raise ValueError("нет файла " + os.path.basename(src))
    os.makedirs(SAVED, exist_ok=True)
    if wav_sec(src) > 20:  # образцу клона хватает 3-20 с
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-t", "20", "-ac", "1", "-ar", "24000",
                        os.path.join(SAVED, nm + ".wav")], check=True)
    else:
        shutil.copyfile(src, os.path.join(SAVED, nm + ".wav"))
    with open(os.path.join(SAVED, nm + ".txt"), "w") as f:  # обрезанный образец - текст уже не совпадает
        f.write(((req.get("text") or "").strip() if wav_sec(src) <= 20 else "") + "\n")
    log("голос сохранён:", nm)
    return saved_voices()


def dl_run(files):
    dl.update(busy=True, err="", stop=False)
    f = ""
    try:
        for f in files:
            d, u = DL[f]
            dst = os.path.join(d, f)
            if os.path.exists(dst):
                continue
            os.makedirs(d, exist_ok=True)
            part = dst + ".part"
            have = os.path.getsize(part) if os.path.exists(part) else 0
            rq = urllib.request.Request(u, headers={"Range": "bytes=%d-" % have, "User-Agent": "fold2-ai"} if have else
                                        {"User-Agent": "fold2-ai"})
            with urllib.request.urlopen(rq, timeout=60) as r:
                if have and r.status != 206:
                    have = 0  # докачка не поддержана - заново
                total = int(r.headers.get("Content-Length") or 0) + have
                dl.update(file=f, got=have, total=total)
                with open(part, "ab" if have else "wb") as o:
                    while True:
                        if dl.get("stop"):
                            raise RuntimeError("остановлено (докачается с того же места)")
                        b = r.read(1 << 20)
                        if not b:
                            break
                        o.write(b)
                        dl["got"] += len(b)
            if dl["total"] and dl["got"] < dl["total"]:
                raise RuntimeError("оборвалось на %d из %d МБ - нажмите ещё раз, докачается" % (dl["got"] >> 20, dl["total"] >> 20))
            os.replace(part, dst)
            log("скачано", dst)
    except Exception as e:
        dl["err"] = "%s: %s" % (f, e)
        log("загрузка:", dl["err"])
    finally:
        dl.update(busy=False, file="", stop=False)


def tts_info():
    files = {f: (os.path.exists(os.path.join(d, f)), os.path.exists(os.path.join(d, f) + ".part")) for f, (d, _) in DL.items()}
    return {"models": qt_models(), "speakers": SPEAKERS, "saved": saved_voices(), "files": files, "qt": qt_ok(),
            "dac": dac_ok(), "dl": {k: dl.get(k) for k in ("file", "got", "total", "err", "busy")}}


_sd_flags = None
_sd_has = {}


def sd_flags():
    # флаги экономии памяти (телефон: ~3 ГБ свободно) - только те, что знает собранный sd-cli
    global _sd_flags
    if _sd_flags is None:
        try:
            h = subprocess.run([SD, "--help"], capture_output=True, text=True, errors="replace").stdout
        except Exception:
            h = ""
        _sd_flags = [f for f in ("--mmap", "--vae-tiling", "--diffusion-fa") if f in h]
        _sd_has.update(taesd="--taesd" in h, preview="--preview-path" in h, preview_only="--taesd-preview-only" in h)
        log("флаги sd-cli:", _sd_flags, _sd_has)
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
    qs_stop()  # FLUX нужна память: модели tts-server выгружаем (загрузятся при следующем голосе, ~4 с)
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
    fast = bool(req.get("fast_decode", cfg.get("fast_decode", True)))
    want_prev = bool(req.get("preview", cfg.get("preview", True)))
    if (fast or want_prev) and _sd_has.get("taesd") and not os.path.exists(TAEF2) and not dl["busy"]:
        st["progress"] = "качаю быстрый декодер TAEF2 (10 МБ)…"
        dl_run(["taef2.safetensors"])
    tae = _sd_has.get("taesd") and os.path.exists(TAEF2)
    try:
        os.remove(PREV)
    except OSError:
        pass
    st.update(preview="", pv=0)

    def mk(use_tae):
        if use_tae and fast:
            dec = ["--taesd", TAEF2]
        elif use_tae and want_prev and _sd_has.get("preview_only"):
            dec = ["--vae", FLUX[1], "--taesd", TAEF2, "--taesd-preview-only"]  # картинка - полный VAE, превью - TAEF2
        else:
            dec = ["--vae", FLUX[1]]
        if use_tae and want_prev and _sd_has.get("preview") and "--taesd" in dec:
            dec += ["--preview", "tae", "--preview-path", PREV]
        return ["taskset", "-c", str(cfg.get("cpus", "4-7"))] + UNBUF + [SD, "--diffusion-model", FLUX[0]] + dec + [
            "--llm", FLUX[2], "-p", prompt, "--cfg-scale", "1.0", "--steps", str(steps), "-W", str(w), "-H", str(h),
            "-t", str(cfg.get("threads", 4)), "-s", str(seed), "-o", fn] + flags + [str(a) for a in cfg.get("args", [])]
    cmd = mk(tae)
    use_fast = tae and fast
    log("sd-cli: ядра", cmd[2], "флаги", flags, "TAEF2" if tae else "без TAEF2", "настройка", cfg)
    # декодер: полный VAE (tiling) ~13 с на 256x256 (замер sdnpu-2); TAEF2 - оценка ~1 с на 512x512 (не замерено)
    vae = (0.3 + 0.7 * w * h / 262144) if use_fast else 13.0 * w * h / 65536
    ph = {"name": "загрузка моделей и кодирование текста", "sampling": False}

    def on_line(line):
        try:  # превью шага (TAEF2) - приложение показывает, как проявляется картинка
            mt = os.path.getmtime(PREV)
            if mt != st.get("pv"):
                st.update(preview=os.path.basename(PREV), pv=mt)
        except OSError:
            pass
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
                st["progress"] = "шаги готовы, декодирую " + ("TAEF2…" if use_fast else "VAE…")
            return
        if "sampling using" in line or "generating image" in line:
            ph["sampling"] = True
        if not ph["sampling"] and not st["eta"]:
            st["progress"] = ph["name"]

    st["progress"] = ph["name"]
    t = time.time()
    rc, tail = run_proc(cmd, on_line)
    if (rc != 0 or not os.path.exists(fn)) and tae and not st["cancel"]:
        log("sd-cli с TAEF2 не вышло, повтор с полным VAE:", " | ".join(tail[-3:]))
        st["progress"] = "TAEF2 не подошёл - повтор с полным VAE…"
        use_fast = False
        vae = 13.0 * w * h / 65536
        rc, tail = run_proc(mk(False), on_line)
    if rc != 0 or not os.path.exists(fn):
        raise RuntimeError("sd-cli код %d:\n%s" % (rc, "\n".join(tail)))
    return fn, {"X-Gen-Sec": "%.1f" % (time.time() - t), "X-Seed": str(seed), "X-Size": "%dx%d" % (w, h),
                "X-Decoder": "TAEF2 (быстрый)" if use_fast else "VAE (полный)"}


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
                                        "sd": SD, "qts": qs_alive(), "parts": st["parts"], "nparts": st["nparts"],
                                        "seed": st["seed"], "preview": st.get("preview", ""), "pv": st.get("pv", 0), "dl": {k: dl[k] for k in ("file", "got", "total", "err", "busy")}},
                                       ensure_ascii=False))
        elif self.path.startswith("/tts_info"):
            self._send(200, json.dumps(tts_info(), ensure_ascii=False))
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
                qs_stop()
            return self._send(200, '{"ok":true}')
        if self.path in ("/download", "/download_stop", "/voice_save", "/voice_del"):  # без общей блокировки
            try:
                if self.path == "/download":
                    fs = [f for f in (req.get("files") or []) if f in DL]
                    if not fs:
                        return self._send(400, '{"error":"нет таких файлов"}')
                    if not dl["busy"]:
                        dl["busy"] = True
                        threading.Thread(target=dl_run, args=(fs,), daemon=True).start()
                elif self.path == "/download_stop":
                    dl["stop"] = True
                elif self.path == "/voice_save":
                    voice_save(req)
                else:
                    nm = req.get("name") or ""
                    if re.fullmatch(VNAME, nm):
                        for ext in (".wav", ".txt"):
                            try:
                                os.remove(os.path.join(SAVED, nm + ext))
                            except OSError:
                                pass
                return self._send(200, json.dumps(tts_info(), ensure_ascii=False))
            except Exception as e:
                return self._send(400, json.dumps({"error": "%s" % e}, ensure_ascii=False))
        job = {"/tts": (do_tts, "audio/wav"), "/image": (do_image, "image/png")}.get(self.path)
        if not job:
            return self._send(404, "{}")
        if not work.acquire(blocking=False):
            return self._send(409, "занято: " + st["busy"], "text/plain; charset=utf-8")
        try:
            st.update(busy=self.path[1:], cancel=False, t0=time.time(), eta=None, progress="", parts=[], nparts=0, preview="")
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
    qs_stop()
    kill_proc()  # не оставлять sd-cli / qwen-tts работать после остановки сервера
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGHUP, bye)
    boost_restore()  # если прошлый сервер упал посреди синтеза
    log("сервер 127.0.0.1:8082, версия", VER, "sd-cli", SD)
    threading.Thread(target=qs_idle, daemon=True).start()
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("127.0.0.1", 8082), H).serve_forever()
