#!/usr/bin/env python3
# Fold2 AI: сервер в Debian на 127.0.0.1:8082 - клон голоса (Qwen3-TTS 0.6B Base) и картинки (FLUX.2 klein 4B,
# stable-diffusion.cpp). Голос: qwentts.cpp (GGML, Q8_0, в разы быстрее) если собран, иначе PyTorch (fp32, медленно).
import base64, gc, glob, hashlib, json, os, queue, re, shutil, signal, subprocess, sys, threading, time, traceback, wave
import urllib.error, urllib.parse, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

VER = 21  # приложение сверяет с /health и перезапускает старый сервер
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
# GPU (OpenCL, Adreno 650) и NPU (F2QDSP, Hexagon cDSP): Android-сборки sd.cpp / qwentts.cpp / whisper.cpp из релиза gpu-N
# (f2ai.sh gpu-install -> /opt/gpu/<что>). Это программы bionic - в Debian они не запускаются: выходим из chroot через корень
# init (/proc/1/root; сервер работает от root) и задаём окружение Android: /vendor/lib64 (OpenCL), пути кода DSP (NPU).
AG = "/opt/gpu"; ANPU = "/data/local/tmp/fold2-npu"
BE_NAME = {"cpu": "CPU", "npu": "NPU + CPU", "gpu": "GPU", "gpu_cpu": "GPU + CPU", "gpu_npu": "GPU + NPU"}


def apath(p):
    """путь в Debian -> тот же файл снаружи chroot (для Android-программ)"""
    p = os.path.abspath(p)
    if p == "/sdcard" or p.startswith("/sdcard/"):
        return "/data/media/0" + p[7:]
    return DAC_ROOT + p


def a_ok(w, b):
    return os.access(os.path.join(AG, w, b), os.X_OK)


def a_npu(w):
    """сборка с F2QDSP (метка <что>.npu из CI) и пакет NPU с кодом для DSP"""
    return os.path.exists(os.path.join(AG, w, w + ".npu")) and os.path.exists("/proc/1/root" + ANPU + "/dsp")


def a_env(w, npu, base=None):
    e = dict(base or os.environ)
    for k in ("LD_PRELOAD", "PYTHONHOME", "PYTHONPATH"):
        e.pop(k, None)
    e["LD_LIBRARY_PATH"] = "/vendor/lib64" + (":" + ANPU + "/lib" if npu else "")
    e["GGML_OPENCL_KERNEL_CACHE_DIR"] = apath(os.path.join(AG, w, "clcache"))  # кернелы OpenCL компилируются один раз
    e["F2QDSP"] = "1" if npu else "0"
    if npu:
        try:
            with open("/proc/1/root" + ANPU + "/dsp.variant") as f:
                eld = f.read().strip() == "eld"
        except OSError:
            eld = False
        e["ADSP_LIBRARY_PATH"] = e["DSP_LIBRARY_PATH"] = (ANPU + "/dsp" + ("/eld" if eld else "") +
                                                          ";/vendor/dsp/cdsp;/vendor/dsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp")
        e.setdefault("F2QDSP_MAX_MB", "1536")
    return e


def a_cmd(w, b, args, cpus=None):
    """Android-программа /opt/gpu/<w>/<b>: текущая папка - её (там кернелы *.cl), ядра - taskset из Debian"""
    d = apath(os.path.join(AG, w))
    return (["taskset", "-c", cpus] if cpus else []) + ["chroot", "/proc/1/root", "/system/bin/sh", "-c",
                                                        'cd "$0" && exec "$@"', d, d + "/" + b] + [str(a) for a in args]
# tts-server (qwentts.cpp): модели остаются в памяти между запросами, голоса регистрируются один раз из кэша
# .spk/.rvq (qwen-codec, бит-в-бит как разбор --ref-wav внутри qwen-tts) - без загрузки (~4 с) и разбора образца (~6 с)
QTS = "/opt/qwentts.cpp/build/tts-server"; QTC = "/opt/qwentts.cpp/build/qwen-codec"; QTS_PORT = 8084
VOICES = M + "/qwentts/voices"  # кэш голосов: <md5 wav>.spk / .rvq
QTD = M + "/qwentts"
SAVED = QTD + "/saved"  # сохранённые голоса: <имя>.wav + .txt (текст образца) + .json + <имя>.<0.6b|1.7b>.spk/.rvq (разобранный голос)
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
VNAME = r"[\w а-яА-ЯёЁ-]{1,40}"
DL = {}  # разрешённые загрузки: имя файла -> (папка, URL)
for _m in ("0.6b-customvoice-Q8_0", "1.7b-customvoice-Q8_0", "1.7b-customvoice-Q4_K_M", "1.7b-voicedesign-Q8_0",
           "1.7b-voicedesign-Q4_K_M", "1.7b-base-Q8_0", "1.7b-base-Q4_K_M"):
    DL["qwen-talker-%s.gguf" % _m] = (QTD, HF_QT + "qwen-talker-%s.gguf" % _m)
for _f in ("Qwen3VL-2B-Instruct-Q4_K_M.gguf", "mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf"):
    DL[_f] = (M, HF_VL + _f)
# распознавание речи (текст образца голоса): whisper.cpp, собранный в CI под Debian arm64 (релиз whisper-1), и модели ggml
WH_DIR = M + "/whisper"; WH_OPT = "/opt/whisper"; WH_BIN = WH_OPT + "/bin/whisper-cli"; WH_TAR = "whisper-linux-arm64.tar.xz"
WH_MODELS = [("ggml-small-q5_1.bin", 190, "small - быстро (~200 МБ)"), ("ggml-small-q8_0.bin", 264, "small Q8_0 - для NPU (~260 МБ)"), ("ggml-large-v3-turbo-q5_0.bin", 574, "large-v3-turbo - точнее (~570 МБ)")]
DL[WH_TAR] = (WH_DIR, "https://github.com/playfixday-droid/fold2-un1ca/releases/download/whisper-1/" + WH_TAR)
for _f, _mb, _t in WH_MODELS:
    DL[_f] = (WH_DIR, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + _f)
PRESETS = M + "/presets"  # настройки голоса файлами: <имя>.json
EXPORT = "/sdcard/Download/Fold2AI"
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


CPUFREQ = "/sys/devices/system/cpu/cpufreq"


def boost_restore():
    # ключи - полные пути (min_freq devfreq, scaling_min_freq cpufreq; так же пишет f2ai.sh boost), старые - имена devfreq
    try:
        with open(BOOST_SAVED) as f:
            saved = json.load(f)
    except Exception:
        return
    for n, v in saved.items():
        if n.startswith("_"):
            continue
        try:
            with open(n if n.startswith("/") else os.path.join(DEVFREQ, n, "min_freq"), "w") as f:
                f.write(str(v))
        except OSError:
            pass
    try:
        os.remove(BOOST_SAVED)
    except OSError:
        pass


def boost_pin(pmin, pmax, saved):
    try:
        with open(pmin) as f:
            v = f.read().strip()
        with open(pmax) as f:
            mx = f.read().strip()
        saved[pmin] = v
        with open(pmin, "w") as f:
            f.write(mx)
    except OSError:
        pass


def boost_on(cfg, gpu, full=False):
    """full - «максимальная скорость» из приложения: ещё и все ядра процессора (cpufreq) на максимальной частоте"""
    if not (full or cfg.get("boost", True)):
        return
    boost_restore()
    saved = {}
    for n in boost_targets(gpu and (full or cfg.get("boost_gpu", False))):  # GPU (DAC) и так на максимуме - без пользы
        d = os.path.join(DEVFREQ, n)
        boost_pin(d + "/min_freq", d + "/max_freq", saved)
    if full:
        for d in sorted(glob.glob(CPUFREQ + "/policy*")):
            boost_pin(d + "/scaling_min_freq", d + "/scaling_max_freq", saved)
    if saved:
        saved["_t"] = int(time.time())
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


ERRL = re.compile(r"(?i)error|assert|abort|fail|unsupported|not supported|out of memory|cannot|can't")


def run_proc(cmd, on_line=None, stdin_text=None, env=None):
    """Запуск sd-cli / qwen-tts с разбором вывода; /cancel убивает процесс (st["proc"]).
    Вывод читается сырыми кусками и режется по \\r и \\n сами: полоса прогресса sd-cli идёт через \\r без
    перевода строки, построчное чтение показывало бы её на шаг позже."""
    if st["cancel"]:
        raise Cancelled()
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    st["proc"] = p
    tail, errs = [], []
    # весь вывод последнего запуска - в /tmp/f2proc.log (Система → Логи); строки с ошибкой - отдельно: при падении
    # хвост - это стек вызовов, а причина выше него
    try:
        lf = open("/tmp/f2proc.log", "w")
        lf.write(" ".join(cmd)[:2000] + "\n")
    except OSError:
        lf = None

    def handle(raw, partial=False):
        line = ANSI.sub("", raw.decode("utf-8", "replace")).strip()
        if not line:
            return
        if not partial:
            tail.append(line)
            del tail[:-15]
            if ERRL.search(line):
                errs.append(line[:400])
                del errs[:-6]
            if lf:
                lf.write(line + "\n")
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
        if lf:
            lf.close()
    if st["cancel"]:
        raise Cancelled()
    if rc:
        tail = [e for e in errs if e not in tail] + tail
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


def qs_stream(body, on_bytes, timeout=1800):
    """POST /v1/audio/speech с response_format pcm: куски s16le по мере генерации -> on_bytes; весь звук - результат"""
    rq = urllib.request.Request("http://127.0.0.1:%d/v1/audio/speech" % QTS_PORT,
                                data=json.dumps(body, ensure_ascii=False).encode(), headers={"Content-Type": "application/json"})
    out = bytearray()
    try:
        with urllib.request.urlopen(rq, timeout=timeout) as f:
            while True:
                b = f.read1(65536)
                if not b:
                    break
                out += b
                on_bytes(b)
                if st["cancel"]:
                    raise Cancelled()  # соединение закроется - tts-server прервёт синтез
    except urllib.error.HTTPError as e:
        raise RuntimeError("tts-server поток: %d %s" % (e.code, e.read()[:300].decode("utf-8", "replace")))
    if len(out) & 1:
        out = out[:-1]
    return bytes(out)


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


def qs_start(env, cpus, model, talker="cpu"):
    """talker: cpu - tts-server Debian; gpu / npu - Android-сборка (OpenCL / F2QDSP): речь (talker) на GPU / NPU"""
    sig = (cpus, model, talker) + tuple(env.get(k) for k in ("QT_THREADS", "QT_REF_SEED", "QT_DAC_EXT", "QT_DAC_MARGIN", "QT_REPACK"))
    if qs_alive() and qs["sig"] == sig:
        return
    qs_stop()
    st["progress"] = "загрузка модели %s%s…" % (os.path.basename(model), {"gpu": " на GPU", "npu": " на NPU"}.get(talker, ""))
    t = time.time()
    if talker == "cpu":
        cmd = ["taskset", "-c", cpus, QTS, "--model", model, "--codec", QTM[1], "--host", "127.0.0.1", "--port", str(QTS_PORT)]
    else:
        e = a_env("qwentts", talker == "npu", env)
        if e.get("QT_DAC_EXT"):
            e["QT_DAC_EXT"] = apath(e["QT_DAC_EXT"])
        if talker == "npu":
            e["QT_REPACK"] = "2"  # веса Q8_0 - в буфер F2QDSP (матрицы на NPU)
        env = e
        cmd = a_cmd("qwentts", "tts-server", ["--model", apath(model), "--codec", apath(QTM[1]), "--host", "127.0.0.1",
                                              "--port", QTS_PORT] + (["--device", "CPU"] if talker == "npu" else []), cpus)
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
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


def md5f(fn):
    with open(fn, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()[:16]


def voice_embed(ref, h, cpus, threads, model, size):
    """образец -> VOICES/<md5>[_1.7b].spk/.rvq (qwen-codec: x-vector тембра и коды образца); один раз на образец"""
    base = os.path.join(VOICES, h if size == "0.6b" else h + "_" + size)  # x-vector у 0.6B и 1.7B разный
    if not (os.path.exists(base + ".spk") and os.path.exists(base + ".rvq")):
        os.makedirs(VOICES, exist_ok=True)
        shutil.copyfile(ref, base + ".wav")
        st["progress"] = "разбираю образец голоса (один раз - потом голос готов сразу)…"
        try:
            rc, tail = run_proc(["taskset", "-c", cpus, QTC, "--model", QTM[1], "--talker", model, "-i", base + ".wav"],
                                lambda l: None, env=dict(os.environ, QT_THREADS=threads))
        finally:
            try:
                os.remove(base + ".wav")
            except OSError:
                pass
        if rc != 0 or not (os.path.exists(base + ".spk") and os.path.exists(base + ".rvq")):
            raise RuntimeError("qwen-codec код %d: %s" % (rc, " | ".join(tail[-4:])))
    return base


def recent_keep(ref, ref_text, h):
    """образец, которым уже говорили (голос «обучен» - разобран), - в VOICES/<md5>.wav + .txt: его можно сохранить
    под именем и позже, даже если запись/файл в приложении уже другие; держим 12 последних"""
    try:
        os.makedirs(VOICES, exist_ok=True)
        w = os.path.join(VOICES, h + ".wav")
        if not os.path.exists(w):
            shutil.copyfile(ref, w)
        with open(os.path.join(VOICES, h + ".txt"), "w") as f:
            f.write(ref_text.strip() + "\n")
        os.utime(w)
        ws = sorted((e for e in os.scandir(VOICES) if e.name.endswith(".wav")), key=lambda e: e.stat().st_mtime, reverse=True)
        for e in ws[12:]:
            for x in (e.path, e.path[:-4] + ".txt"):
                try:
                    os.remove(x)
                except OSError:
                    pass
    except Exception as e:
        log("недавний голос не записан:", e)


def saved_emb(nm, size):
    b = os.path.join(SAVED, "%s.%s" % (nm, size))
    return b if os.path.exists(b + ".spk") and os.path.exists(b + ".rvq") else None


def qs_voice(ref, ref_text, cpus, threads, model, size, saved=""):
    """регистрирует голос в tts-server. saved - сохранённый голос: его разбор лежит рядом с ним
    (SAVED/<имя>.<размер>.spk/.rvq) и переживает переустановку приложения и чистку кэша"""
    base = saved_emb(saved, size) if saved else None
    if not base:
        h = md5f(ref)
        base = voice_embed(ref, h, cpus, threads, model, size)
        if saved:  # первый раз этим сохранённым голосом на этой модели - разбор кладём к нему
            try:
                for ext in (".spk", ".rvq"):
                    shutil.copyfile(base + ext, os.path.join(SAVED, "%s.%s%s" % (saved, size, ext)))
            except OSError as e:
                log("разбор голоса не сохранён:", e)
        else:
            recent_keep(ref, ref_text, h)
    with open(base + ".spk", "rb") as f:
        spk_raw = f.read()
    with open(base + ".rvq", "rb") as f:
        rvq_raw = f.read()
    name = "v%s_%s" % (hashlib.md5(spk_raw + rvq_raw).hexdigest()[:16], hashlib.md5(ref_text.encode()).hexdigest()[:8])
    if name in qs["voices"]:
        return name
    qs_http("/v1/audio/voices", {"name": name, "ref_text": ref_text, "spk_b64": base64.b64encode(spk_raw).decode(),
                                 "rvq_b64": base64.b64encode(rvq_raw).decode()}, 120)
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
# ядра: SD865 = 4 малых (0-3) + 3 больших (4-6) + 1 главное (7). Замер qwen-tts 0.6B на телефоне (фраза 5 с, DAC на CPU):
# 4 потока с маской 0-7 - 107-110 мс/кадр, 25 с; 4 потока на 4-7 - 194-196 мс/кадр, 31 с; 3 потока на 4-6 - 154-183 мс/кадр,
# 34-42 с; 5 / 6 / 8 потоков на 0-7 - 606 / 699 / 781 мс/кадр, 58-64 с (лишний поток попадает на малое ядро, и каждый шаг
# ждёт его - в 4-5 раз медленнее). Привязка к большим ядрам мешает планировщику: на них же экран/DeX, а поток ggml
# ждёт, пока его ядро освободится; с маской 0-7 планировщик держит потоки на свободных больших ядрах.
CPU_SETS = {"auto": ("0-7", 4), "big": ("4-7", 4), "big3": ("4-6", 3), "all": ("0-7", 8), "all6": ("0-7", 6)}
LITTLE = ["taskset", "-c", "0-3"]  # ffmpeg (эффекты по графикам) - на малых ядрах, пока большие пишут следующую фразу
cpu_last = {"tts": None}


RE_CPUS = re.compile(r"[0-7](-[0-7])?(,[0-7](-[0-7])?){0,7}")


def cpu_req(req):
    """свои ядра и потоки из приложения: {"cpus": "0-3,7", "threads": 4} -> ("0-3,7", 4) или None"""
    cs = str(req.get("cpus") or "")
    try:
        th = int(req.get("threads") or 0)
    except (TypeError, ValueError):
        th = 0
    return (cs, max(1, min(8, th))) if RE_CPUS.fullmatch(cs) and th > 0 else None


def cpu_pick(req, cfg, kind="tts"):
    """(маска ядер, потоки): свои ядра/потоки или пресет из приложения > qt.json / sd.json > авто"""
    c = cpu_req(req) or CPU_SETS.get(str(req.get("cpu") or ""))
    if not c:
        c = (str(cfg.get("cpus", "0-7")), int(cfg.get("threads", 4))) if "cpus" in cfg else CPU_SETS["auto"]
    if kind == "tts":
        cpu_last["tts"] = c
    return c


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


_rb = None


def has_rubberband():
    """ffmpeg c librubberband (в Debian есть): плавная смена высоты/темпа по графику, с сохранением формант"""
    global _rb
    if _rb is None:
        try:
            out = subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True, timeout=30).stdout
            _rb = bool(re.search(r"\srubberband\s", out)) and bool(re.search(r"\sasendcmd\s", out))
        except Exception:
            _rb = False
        log("ffmpeg rubberband:", _rb)
    return _rb


FX_LIM = {"pitch": (-12.0, 12.0, 0.0), "tempo": (0.5, 2.0, 1.0), "gain": (-30.0, 12.0, 0.0)}


def fx_clean(fx):
    """графики фразы: {"pitch": [[u, полутоны]], "tempo": [[u, x]], "gain": [[u, дБ]]}, u - доля фразы 0..1"""
    out = {}
    if not isinstance(fx, dict):
        return out
    for k, (lo, hi, _) in FX_LIM.items():
        pts = []
        for pv in (fx.get(k) or [])[:600]:
            try:
                u, v = float(pv[0]), float(pv[1])
            except (TypeError, ValueError, IndexError):
                continue
            pts.append((min(1.0, max(0.0, u)), min(hi, max(lo, v))))
        if pts:
            out[k] = sorted(pts)
    return out


def curve(pts, u, d):
    if not pts:
        return d
    if u <= pts[0][0]:
        return pts[0][1]
    for (u0, v0), (u1, v1) in zip(pts, pts[1:]):
        if u <= u1:
            return v0 if u1 - u0 < 1e-9 else v0 + (v1 - v0) * (u - u0) / (u1 - u0)
    return pts[-1][1]


def atempo_chain(t):
    af = []
    while t > 2:
        af.append("atempo=2")
        t /= 2
    while t < 0.5:
        af.append("atempo=0.5")
        t /= 0.5
    return af + ["atempo=%.4f" % t]


def post_fx(wav, tempo, pitch, fx=None):
    """темп (без смены высоты), высота тона (полутоны) и громкость (дБ): ползунки на всю фразу + графики по словам.
    Модель сама так не умеет (speed она игнорирует). С rubberband - плавно по графику и с сохранением формант
    (голос не «мультяшный»), иначе - среднее по фразе через asetrate/atempo"""
    fx = fx or {}
    if abs(tempo - 1) < 0.01 and abs(pitch) < 0.05 and not fx:
        return True
    P, T, G = fx.get("pitch"), fx.get("tempo"), fx.get("gain")
    tmp, cmdf = wav + ".fx.wav", wav + ".cmd"
    try:
        dur = max(0.05, wav_sec(wav))
        lim = lambda k, v: min(FX_LIM[k][1], max(FX_LIM[k][0], v))
        val = lambda u: (lim("pitch", pitch + curve(P, u, 0.0)), lim("tempo", tempo * curve(T, u, 1.0)), lim("gain", curve(G, u, 0.0)))
        if has_rubberband():
            p0, t0, g0 = val(0.0)
            af = []
            if P or T or G:
                lines, prev, t = [], (p0, t0, g0), 0.04
                while t < dur:
                    p, tm, g = val(t / dur)
                    if abs(p - prev[0]) > 0.04 or abs(tm - prev[1]) > 0.004 or abs(g - prev[2]) > 0.1:
                        lines.append("%.3f rubberband pitch %.5f, rubberband tempo %.4f, volume volume %.4f;"
                                     % (t, 2 ** (p / 12.0), tm, 10 ** (g / 20.0)))
                        prev = (p, tm, g)
                    t += 0.04
                with open(cmdf, "w") as f:
                    f.write("\n".join(lines) + "\n")
                if lines:
                    af.append("asendcmd=f=" + cmdf)
            af.append("rubberband=pitch=%.5f:tempo=%.4f:formant=preserved:pitchq=consistency" % (2 ** (p0 / 12.0), t0))
            af.append("volume=volume=%.4f" % (10 ** (g0 / 20.0)))
        else:
            us = [i / 20.0 for i in range(21)]
            p = sum(val(u)[0] for u in us) / 21
            tm = sum(val(u)[1] for u in us) / 21
            g = sum(val(u)[2] for u in us) / 21
            r = 2 ** (p / 12.0) if abs(p) >= 0.05 else 1.0
            af = (["asetrate=%d" % round(24000 * r), "aresample=24000"] if r != 1.0 else []) + atempo_chain(tm / r)
            if abs(g) >= 0.1:
                af.append("volume=%.2fdB" % g)
        subprocess.run(LITTLE + ["ffmpeg", "-y", "-loglevel", "error", "-threads", "2", "-i", wav, "-af", ",".join(af), "-ar", "24000",
                                 "-ac", "1", "-c:a", "pcm_s16le", tmp], check=True, timeout=180)
        os.replace(tmp, wav)
        return True
    except Exception as e:
        log("эффекты темп/тон/громкость не применились:", e)
        return False
    finally:
        for x in (tmp, cmdf):
            try:
                os.remove(x)
            except OSError:
                pass


def wav_pad(fn, ms):
    """тишина в конце фразы - пауза, заданная на графике (звучит и при проигрывании по фразам)"""
    if ms <= 0:
        return
    with wave.open(fn) as w:
        prm, data = w.getparams(), w.readframes(w.getnframes())
    with wave.open(fn, "wb") as out:
        out.setparams(prm)
        out.writeframes(data + b"\0" * (int(prm.framerate * ms / 1000) * prm.sampwidth * prm.nchannels))


def wav_concat(parts, fn, gap_ms=90):
    """gap_ms - одна пауза на все стыки или список по стыкам"""
    with wave.open(parts[0]) as w0:
        prm = w0.getparams()
    gaps = gap_ms if isinstance(gap_ms, list) else [gap_ms] * len(parts)
    with wave.open(fn, "wb") as out:
        out.setparams(prm)
        for i, p in enumerate(parts):
            with wave.open(p) as w:
                out.writeframes(w.readframes(w.getnframes()))
            if i < len(parts) - 1 and gaps[i] > 0:
                out.writeframes(b"\0" * (int(prm.framerate * gaps[i] / 1000) * prm.sampwidth * prm.nchannels))


def plan_parse(req):
    """план с графиков приложения: фразы со своей инструкцией (эмоции по словам), живостью, паузой после
    и графиками высоты/темпа/громкости. None - обычный текст"""
    pl = req.get("plan")
    segs = pl.get("segments") if isinstance(pl, dict) else None
    if not isinstance(segs, list):
        return None
    out = []
    for sg in segs[:300]:
        if not isinstance(sg, dict):
            continue
        t = str(sg.get("text") or "").strip()[:1500]
        if not t:
            continue
        tp = sg.get("temperature")
        try:
            tp = None if tp is None or tp == "" else min(2.0, max(0.05, float(tp)))
        except (TypeError, ValueError):
            tp = None
        out.append({"text": t, "instruct": str(sg.get("instruct") or "").strip()[:1200], "temp": tp,
                    "pause": int(min(5000, max(0, num(sg.get("pause"), 0)))), "fx": fx_clean(sg.get("fx"))})
    return out or None


def do_tts_qt(req, text, ref, ref_text):
    unload_tts()
    cfg = qt_cfg()
    mode = req.get("mode") if req.get("mode") in KIND else "clone"
    kind = KIND[mode]
    # инструкции (интонация, эмоция, темп, манера) понимают CustomVoice и VoiceDesign; Base (клон) их отвергает
    instruct = (req.get("instruct") or "").strip()[:1200]
    plan = plan_parse(req)  # графики: у каждой фразы своя инструкция / живость / пауза / высота-темп-громкость
    if plan:
        for sg in plan:
            if kind == "voicedesign" and not sg["instruct"]:
                sg["instruct"] = instruct  # описание голоса нужно в каждой фразе
    note = ""
    if kind == "base":  # Base (клон) инструкций не понимает - эмоции только у CustomVoice / VoiceDesign 1.7B
        if instruct or (plan and any(sg["instruct"] for sg in plan)):
            note = " · эмоции пропущены: клон (Base) их не понимает"
        instruct = ""
        for sg in plan or []:
            sg["instruct"] = ""
    has_ins = bool(instruct) or bool(plan and any(sg["instruct"] for sg in plan))
    if kind == "voicedesign" and not (instruct if not plan else all(sg["instruct"] for sg in plan)):
        raise ValueError("опишите голос - поле «Какой голос»")
    pk = qt_pick(kind, str(req.get("size") or ""), big=kind == "voicedesign" or has_ins, quant=str(cfg.get("quant", "")))
    if not pk:
        raise RuntimeError(MISSING[kind])
    model, size, quant = pk
    if has_ins and size == "0.6b":  # 0.6B CustomVoice инструкций не понимает (у Qwen интонации - только 1.7B)
        instruct, note = "", " · эмоции/интонации пропущены: нужна модель 1.7B"
        for sg in plan or []:
            sg["instruct"] = ""
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
        if f.startswith(("part_", "stream_")):
            try:
                os.remove(os.path.join(OUT, f))
            except OSError:
                pass
    cpus, nthr = cpu_pick(req, cfg)
    # речь (talker + предсказатель кодов): cpu - Debian; gpu / npu - Android-сборка qwentts.cpp (только через tts-server)
    talker = str(req.get("talker") or "cpu")
    talker = talker if talker in ("cpu", "gpu", "npu") else "cpu"
    if talker != "cpu" and not a_ok("qwentts", "tts-server"):
        raise RuntimeError("нет GPU/NPU-версии qwentts.cpp - «Мощность» → «⬇ GPU и NPU-версии»")
    if talker == "npu" and not a_npu("qwentts"):
        raise RuntimeError("NPU для голоса недоступен: нужна сборка qwentts.cpp с NPU и пакет NPU")
    # результат от числа потоков не зависит (md5 тот же). QT_REPACK=1: веса Q8_0 в CPU_REPACK (dotprod-ядра 4x4) -
    # та же точность, ~30% быстрее. QT_REF_SEED - затравка клона.
    env = dict(os.environ, QT_THREADS=str(nthr))
    env["QT_REPACK"] = "1" if cfg.get("repack", True) else "0"
    env["QT_REF_SEED"] = str(int(cfg.get("ref_seed", 144)))
    # поток: tts-server отдаёт s16le 24 кГц по мере генерации (кодек декодирует кадр за кадром на процессоре) -
    # звук начинает играть раньше; темп/тон/графики громкости в потоке не применить - тогда обычный режим
    stream = (bool(req.get("stream")) and qs_ok(cfg) and abs(tempo - 1) < 0.01 and abs(pitch) < 0.05
              and not any(sg.get("fx") for sg in plan or []))
    gpu = bool(req.get("dac_gpu", cfg.get("dac_gpu", True))) and dac_ok() and not stream  # выключатель «DAC на GPU»
    if gpu:
        # GPU уступает экрану (DeX): низкий приоритет контекстов OpenCL, куски не длиннее 128 кадров, пауза 2 мс
        dex = req.get("dex", cfg.get("dex", True))
        try:
            log("dacgpu:", dac_req("cfg prio=%s maxn=%d gap=%d" % (("low", 128, 2) if dex else ("normal", 0, 0)), 5))
        except Exception:
            pass
        env["QT_DAC_EXT"] = DAC_LAT
        threading.Thread(target=lambda: dac_req("load", 60), daemon=True).start()  # модели DAC на GPU заранее
    if plan:
        chunks = [sg["text"] for sg in plan]
    else:
        chunks = split_text(text) if req.get("split", cfg.get("split", True)) else [text]
        plan = [{"text": ch, "instruct": instruct, "temp": None, "pause": 0, "fx": {}} for ch in chunks]
    n = len(chunks)
    st.update(parts=[], nparts=n, seed=seed)
    sfn = OUT + "/stream_%s.pcm" % stamp
    st["stream"] = None
    if stream:
        open(sfn, "wb").close()
        st["stream"] = {"name": os.path.basename(sfn), "bytes": 0, "done": False, "sr": 24000}
    body0 = dict({"language": lang, "response_format": "wav", "seed": seed}, **samp)
    saved = str(req.get("_saved") or "")
    if kind == "base" and ref_text:
        with open("/tmp/ref_text.txt", "w") as f:
            f.write(ref_text + "\n")
    S = {"server": qs_ok(cfg), "voice": None, "backend": "", "gpu_used": 0, "gpu_busy": "", "fx": True, "stream": stream}

    def s_add(b):
        with open(sfn, "ab") as f:
            f.write(b)
        st["stream"]["bytes"] += len(b)

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

    def cli(i, ch, wav, e2, on_line):
        cmd = ["taskset", "-c", cpus, QT, "--model", model, "--codec", QTM[1], "--lang", lang,
               "--max-new", str(max_new(ch)), "--seed", str(seed)]
        sp = dict(samp)
        if plan[i]["temp"] is not None:
            sp["temperature"] = plan[i]["temp"]
        for k, v in sp.items():
            cmd += [SAMP[k][3], str(v)]
        if kind == "base":
            cmd += ["--ref-wav", ref] + (["--ref-text", "/tmp/ref_text.txt"] if ref_text else [])
        if speaker:
            cmd += ["--speaker", speaker]
        if plan[i]["instruct"]:
            cmd += ["--instruct", plan[i]["instruct"]]
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
                qs_start(env, cpus, model, talker)
                if kind == "base" and S["voice"] is None:
                    S["voice"] = qs_voice(ref, ref_text, cpus, env["QT_THREADS"], model, size, saved)
                body = dict(body0, input=ch, max_new_tokens=max_new(ch))
                if plan[i]["instruct"]:
                    body["instructions"] = plan[i]["instruct"]
                if plan[i]["temp"] is not None:
                    body["temperature"] = plan[i]["temp"]
                if S["voice"] or speaker:
                    body["voice"] = S["voice"] or speaker
                st["progress"] = ("фраза %d/%d: " % (i + 1, n) if n > 1 else "") + "генерирую…" + S["gpu_busy"]
                qs.update(on_line=on_line, busy=True)
                try:
                    if S["stream"]:
                        body["response_format"] = "pcm"
                        pcm = qs_stream(body, s_add)
                        if i < n - 1:  # пауза после фразы - и в потоке
                            s_add(b"\0\0" * (24 * (plan[i]["pause"] or int(cfg.get("gap_ms", 90)))))
                    else:
                        data = qs_http("/v1/audio/speech", body, 1800)
                finally:
                    qs.update(on_line=None, busy=False, last=time.time())
                if st["cancel"]:
                    raise Cancelled()
                if S["stream"]:
                    with wave.open(wav, "wb") as w:
                        w.setnchannels(1)
                        w.setsampwidth(2)
                        w.setframerate(24000)
                        w.writeframes(pcm)
                else:
                    with open(wav, "wb") as f:  # с QT_DAC_EXT - тишина нужной длины, звук запишет dacgpu
                        f.write(data)
                S["backend"] = "qwentts.cpp %s %s (сервер%s%s)" % (size, quant, ", поток" if S["stream"] else "",
                                                                  {"gpu": ", речь на GPU", "npu": ", речь на NPU + CPU"}.get(talker, ""))
                done = True
            except Cancelled:
                raise
            except Exception as e:
                if st["cancel"]:
                    raise Cancelled()
                log("tts-server не справился, запасной путь qwen-tts:", e)
                qs_stop()
                S["server"] = False
                if S["stream"]:
                    S["stream"] = False
                    st["stream"]["err"] = "поток не вышел: %s" % e
        if not done:
            e2 = dict(env)
            if cpu_only:
                e2.pop("QT_DAC_EXT", None)
            cli(i, ch, wav, e2, on_line)
            if kind == "base" and not saved and not S.get("kept"):
                S["kept"] = True
                recent_keep(ref, ref_text, md5f(ref))
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
        S["fx"] = post_fx(wav, tempo, pitch, plan[i]["fx"]) and S["fx"]
        if i < n - 1:
            wav_pad(wav, plan[i]["pause"] or int(cfg.get("gap_ms", 90)))
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
    boost_on(cfg, gpu, bool(req.get("max")))
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
        if st.get("stream"):
            st["stream"]["done"] = True
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
        wav_concat(ready, fn, 0)  # паузы уже в конце фраз
    dt = time.time() - t
    be = S["backend"] + (" + DAC на GPU" if S["gpu_used"] else "")
    if n > 1:
        be += " · %d фраз, процессор и GPU параллельно" % n if S["gpu_used"] else " · %d фраз" % n
    if not S["fx"]:
        be += " · без темпа/тона/громкости (ffmpeg не справился)"
    be += note
    log("qwen-tts:", " | ".join(qs["tail"][-3:]))
    return fn, {"X-Gen-Sec": "%.2f" % dt, "X-Audio-Sec": "%.2f" % wav_sec(fn), "X-Backend": be, "X-Seed": str(seed),
                "X-Model": os.path.basename(model), "X-Parts": str(n), "X-Mode": mode}


def saved_voices():
    """сохранённые голоса; ready - для каких моделей клона голос уже разобран (звучит сразу, без разбора образца)"""
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
                try:
                    with open(os.path.join(SAVED, nm + ".json")) as t:
                        meta = json.load(t)
                except (OSError, ValueError):
                    meta = {}
                out.append({"name": nm, "text": tx, "sec": round(wav_sec(os.path.join(SAVED, f)), 1),
                            "ready": [z for z in ("0.6b", "1.7b") if saved_emb(nm, z)], "meta": meta})
    except OSError:
        pass
    return out


def recent_voices():
    """недавно «обученные» (разобранные) образцы, ещё не сохранённые под именем"""
    have = {v["meta"].get("md5") for v in saved_voices()}
    out = []
    try:
        ws = sorted((e for e in os.scandir(VOICES) if e.name.endswith(".wav")), key=lambda e: e.stat().st_mtime, reverse=True)
    except OSError:
        ws = []
    for e in ws:
        h = e.name[:-4]
        if h in have or not re.fullmatch(r"[0-9a-f]{16}", h):
            continue
        try:
            with open(os.path.join(VOICES, h + ".txt")) as t:
                tx = t.read().strip()
        except OSError:
            tx = ""
        out.append({"id": h, "text": tx, "sec": round(wav_sec(e.path), 1), "t": int(e.stat().st_mtime),
                    "ready": [z for z in ("0.6b", "1.7b") if os.path.exists(os.path.join(VOICES, h if z == "0.6b" else h + "_" + z) + ".spk")]})
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
        req["_saved"] = nm
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


APPF = "/sdcard/Android/data/com.fold2.ai/files/"


def voice_save(req):
    """сохранить голос под именем. Источник: recent - недавно обученный образец (id), ref - образец клона
    ("sample" или файл приложения), file - готовая озвучка из out (дизайн / готовый голос -> клон).
    Разбор голоса (.spk/.rvq), если этот образец уже озвучивали, копируется сразу - голос «обучен» и готов"""
    nm = (req.get("name") or "").strip()
    if not re.fullmatch(VNAME, nm):
        raise ValueError("имя: буквы, цифры, пробел, - _ (до 40 символов)")
    text = (req.get("text") or "").strip()
    meta = {"created": time.strftime("%Y-%m-%d %H:%M")}
    for k in ("mode", "speaker", "instruct", "seed", "src"):
        if req.get(k) not in (None, ""):
            meta[k] = str(req.get(k))[:1200]
    if req.get("recent"):
        h = str(req["recent"])
        src = os.path.join(VOICES, h + ".wav")
        if not re.fullmatch(r"[0-9a-f]{16}", h) or not os.path.isfile(src):
            raise ValueError("нет такого образца")
        if not text:
            try:
                with open(os.path.join(VOICES, h + ".txt")) as f:
                    text = f.read().strip()
            except OSError:
                pass
        meta.setdefault("src", "образец")
    elif req.get("ref"):
        r = str(req["ref"])
        if r == "sample":
            if not os.path.exists(SAMPLE):
                subprocess.run(["curl", "-fsSL", "-o", SAMPLE,
                                "https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-TTS-Repo/clone.wav"], check=True)
            r = SAMPLE
        elif not os.path.realpath(r).startswith(APPF) or not os.path.isfile(r):
            raise ValueError("нет файла образца")
        src = to_wav(r)  # тот же файл, что идёт в клон: md5 совпадёт с кэшем разбора
        meta.setdefault("src", "образец")
    else:
        src = os.path.join(OUT, os.path.basename(req.get("file") or ""))
        if not os.path.isfile(src) or not src.endswith(".wav"):
            raise ValueError("нет файла " + os.path.basename(src))
        meta.setdefault("src", "озвучка")
    os.makedirs(SAVED, exist_ok=True)
    dst = os.path.join(SAVED, nm + ".wav")
    for f in os.listdir(SAVED):  # перезапись под тем же именем - старый разбор не годится
        if f.startswith(nm + ".") and f[len(nm) + 1:] in ("wav", "txt", "json", "0.6b.spk", "0.6b.rvq", "1.7b.spk", "1.7b.rvq"):
            os.remove(os.path.join(SAVED, f))
    sec = wav_sec(src)
    if sec > 20:  # образцу клона хватает 3-20 с; обрезанный - текст уже не совпадает
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-t", "20", "-ac", "1", "-ar", "24000", dst], check=True)
        text = ""
        h = None
    else:
        shutil.copyfile(src, dst)
        h = md5f(src)
    with open(os.path.join(SAVED, nm + ".txt"), "w") as f:
        f.write(text + "\n")
    got = []
    if h:
        meta["md5"] = h
        for z in ("0.6b", "1.7b"):  # уже разобранный голос - сразу к сохранённому
            b = os.path.join(VOICES, h if z == "0.6b" else h + "_" + z)
            if os.path.exists(b + ".spk") and os.path.exists(b + ".rvq"):
                for ext in (".spk", ".rvq"):
                    shutil.copyfile(b + ext, os.path.join(SAVED, "%s.%s%s" % (nm, z, ext)))
                got.append(z)
    with open(os.path.join(SAVED, nm + ".json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False)
    log("голос сохранён:", nm, "разбор:", got or "нет - сделаю")
    if req.get("prep", True):
        threading.Thread(target=voice_prep, args=(nm,), daemon=True).start()
    return got


def voice_prep(nm):
    """«обучить» сохранённый голос заранее: разбор образца для всех моделей клона, что есть (по ~5-15 с) -
    потом этим голосом говорит сразу. Если идёт озвучка/картинка - разберётся при первом использовании"""
    todo = [z for z in ("0.6b", "1.7b") if qt_pick("base", z) and not saved_emb(nm, z)]
    if not todo or not qt_ok() or not qs_ok(qt_cfg()) or not work.acquire(timeout=5):
        return
    try:
        st.update(busy="prep", cancel=False, t0=time.time(), eta=None, parts=[], nparts=0, stream=None, sid="prep")
        cpus, nthr = cpu_last["tts"] or cpu_pick({}, qt_cfg(), "prep")
        ref = to_wav(os.path.join(SAVED, nm + ".wav"))
        h = md5f(ref)
        for z in todo:
            st["progress"] = "готовлю голос «%s» для %s…" % (nm, z.upper())
            model = qt_pick("base", z)[0]
            b = voice_embed(ref, h, cpus, str(nthr), model, z)
            for ext in (".spk", ".rvq"):
                shutil.copyfile(b + ext, os.path.join(SAVED, "%s.%s%s" % (nm, z, ext)))
            log("голос «%s» готов для %s" % (nm, z))
    except Exception as e:
        log("голос не подготовлен:", e)
    finally:
        st.update(busy="", progress="", cancel=False)
        work.release()


def voice_del(nm):
    if not re.fullmatch(VNAME, nm):
        return
    for f in os.listdir(SAVED) if os.path.isdir(SAVED) else []:
        if f.startswith(nm + ".") and f[len(nm) + 1:] in ("wav", "txt", "json", "0.6b.spk", "0.6b.rvq", "1.7b.spk", "1.7b.rvq"):
            try:
                os.remove(os.path.join(SAVED, f))
            except OSError:
                pass


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


def asr_bin():
    if os.access(WH_BIN, os.X_OK):
        return WH_BIN
    tf = os.path.join(WH_DIR, WH_TAR)
    if os.path.exists(tf):  # скачан архив - распаковать в /opt/whisper (bin/whisper-cli)
        import tarfile
        os.makedirs(WH_OPT, exist_ok=True)
        with tarfile.open(tf) as t:
            t.extractall(WH_OPT)
        for f in glob.glob(WH_OPT + "/bin/*"):
            os.chmod(f, 0o755)
        if os.access(WH_BIN, os.X_OK):
            return WH_BIN
    return None


def asr_info():
    return {"bin": os.access(WH_BIN, os.X_OK) or os.path.exists(os.path.join(WH_DIR, WH_TAR)) or a_ok("whisper", "whisper-cli"),
            "models": [f for f, _, _ in WH_MODELS if os.path.exists(os.path.join(WH_DIR, f))],
            "all": [[f, mb, t] for f, mb, t in WH_MODELS]}


def sample_get():
    if not os.path.exists(SAMPLE):
        subprocess.run(["curl", "-fsSL", "-o", SAMPLE + ".part",
                        "https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-TTS-Repo/clone.wav"], check=True)
        os.replace(SAMPLE + ".part", SAMPLE)
    return SAMPLE


def ref_src(r):
    """образец голоса из приложения -> файл: sample, saved:<имя>, ~<md5> (недавний), путь в /sdcard"""
    r = str(r or "")
    if r in ("", "sample"):
        return sample_get()
    if r.startswith("saved:"):
        nm = r[6:]
        fn = os.path.join(SAVED, nm + ".wav")
        if re.fullmatch(VNAME, nm) and os.path.exists(fn):
            return fn
    elif r.startswith("~"):
        fn = os.path.join(VOICES, r[1:] + ".wav")
        if re.fullmatch(r"~[0-9a-f]{32}", r) and os.path.exists(fn):
            return fn
    elif r.startswith("/sdcard/") and ".." not in r and os.path.isfile(r):
        return r
    raise ValueError("нет образца " + r)


ASR_LANG = {"Russian": "ru", "English": "en", "Chinese": "zh", "German": "de", "French": "fr", "Spanish": "es",
            "Italian": "it", "Portuguese": "pt", "Japanese": "ja", "Korean": "ko", "Auto": "auto"}


def do_asr(req):
    b = asr_bin()
    have = asr_info()["models"]
    if not (b or a_ok("whisper", "whisper-cli")) or not have:
        raise RuntimeError("нет распознавания речи - «⬇ Распознавание» в «Мощность»")
    model = req.get("model") if req.get("model") in have else have[0]
    src = ref_src(req.get("ref"))
    lang = ASR_LANG.get(str(req.get("lang") or ""), "auto")
    key = "%s|%s|%s" % (md5f(src), model, lang)
    cf = os.path.join(WH_DIR, "cache.json")
    try:
        with open(cf) as f:
            cache = json.load(f)
    except Exception:
        cache = {}
    if key in cache and not req.get("nocache"):  # nocache - распознать заново (проверка CPU / GPU / NPU)
        return src, {"text": cache[key], "X-Cached": "1", "X-Model": model}
    st["progress"] = "распознаю речь (%s)…" % model.replace("ggml-", "").replace(".bin", "")
    wav16 = "/tmp/asr_in.wav"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-ac", "1", "-ar", "16000", "-t", "30",
                    "-c:a", "pcm_s16le", wav16], check=True)
    cpus, thr = cpu_req(req) or ("4-7", 4)
    t = time.time()
    try:
        os.remove("/tmp/asr_out.txt")
    except OSError:
        pass
    # где считать: cpu - Debian whisper-cli (или Android без GPU); gpu - Android (OpenCL); npu - Android, F2QDSP: на NPU
    # идут только веса Q4_0 / Q8_0 (модель *-q8_0), с q5 - всё на CPU
    be = str(req.get("be") or "cpu")
    be = be if be in ("cpu", "gpu", "npu") else "cpu"
    if be != "cpu" or b is None:
        if not a_ok("whisper", "whisper-cli"):
            raise RuntimeError("нет GPU/NPU-версии whisper.cpp - «Мощность» → «⬇ GPU и NPU-версии»")
        if be == "npu" and not a_npu("whisper"):
            raise RuntimeError("NPU для распознавания недоступен: нужна сборка whisper.cpp с NPU и пакет NPU")
        args = ["-m", apath(os.path.join(WH_DIR, model)), "-f", apath(wav16), "-l", lang, "-t", thr, "-nt", "-otxt",
                "-of", apath("/tmp/asr_out")] + (["-ng"] if be != "gpu" else ["-nfa"])  # flash attention на Adreno - мусор (whisper.cpp#3935)
        rc, tail = run_proc(a_cmd("whisper", "whisper-cli", args, cpus), env=a_env("whisper", be == "npu"))
    else:
        rc, tail = run_proc(["taskset", "-c", cpus, b, "-m", os.path.join(WH_DIR, model), "-f", wav16, "-l", lang,
                             "-t", str(thr), "-nt", "-otxt", "-of", "/tmp/asr_out"])
    if st["cancel"]:
        raise Cancelled()
    try:
        with open("/tmp/asr_out.txt") as f:
            text = " ".join(x.strip() for x in f.read().splitlines() if x.strip())
    except OSError:
        raise RuntimeError("whisper код %d:\n%s" % (rc, "\n".join(tail[-6:])))
    cache[key] = text
    try:
        with open(cf, "w") as f:
            json.dump(dict(list(cache.items())[-200:]), f, ensure_ascii=False)
    except OSError:
        pass
    return src, {"text": text, "X-Gen-Sec": "%.1f" % (time.time() - t), "X-Model": model, "X-Backend": BE_NAME[be]}


def presets():
    out = []
    for f in sorted(glob.glob(PRESETS + "/*.json"), key=os.path.getmtime, reverse=True):
        try:
            with open(f) as x:
                out.append({"name": os.path.basename(f)[:-5], "t": int(os.path.getmtime(f)), "data": json.load(x)})
        except Exception:
            pass
    return out


def tts_info():
    files = {f: (os.path.exists(os.path.join(d, f)), os.path.exists(os.path.join(d, f) + ".part")) for f, (d, _) in DL.items()}
    return {"models": qt_models(), "speakers": SPEAKERS, "saved": saved_voices(), "recent": recent_voices(), "files": files,
            "qt": qt_ok(), "rubberband": has_rubberband(),
            "dac": dac_ok(), "asr": asr_info(), "dl": {k: dl.get(k) for k in ("file", "got", "total", "err", "busy")}}


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
    # картинки: по умолчанию как раньше (4 потока на 4-7, замерено sdnpu); выбор в приложении - поверх sd.json
    icpu = cpu_req(req) or CPU_SETS.get(str(req.get("cpu") or "")) or (str(cfg.get("cpus", "4-7")), int(cfg.get("threads", 4)))
    # где считать: cpu - Debian sd-cli (repack); остальное - Android sd-cli (OpenCL + F2QDSP): npu - всё на CPU, матрицы
    # весов Q4_0 на NPU; gpu - всё на GPU; gpu_cpu / gpu_npu - FLUX и декодер на GPU, текстовый энкодер Qwen3-4B на CPU / NPU
    be = str(req.get("be") or "cpu")
    be = be if be in BE_NAME else "cpu"
    if be != "cpu" and not a_ok("sdcpp", "sd-cli"):
        raise RuntimeError("нет GPU/NPU-версии sd.cpp - «Мощность» → «⬇ GPU и NPU-версии»")
    if be in ("npu", "gpu_npu") and not a_npu("sdcpp"):
        raise RuntimeError("NPU для картинки недоступен: нужна сборка sd.cpp с NPU и пакет NPU (Система → Тест NPU)")
    A = (lambda x: x) if be == "cpu" else apath
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
            dec = ["--taesd", A(TAEF2)]
        elif use_tae and want_prev and _sd_has.get("preview_only"):
            dec = ["--vae", A(FLUX[1]), "--taesd", A(TAEF2), "--taesd-preview-only"]  # картинка - полный VAE, превью - TAEF2
        else:
            dec = ["--vae", A(FLUX[1])]
        if use_tae and want_prev and _sd_has.get("preview") and "--taesd" in dec:
            dec += ["--preview", "tae", "--preview-path", A(PREV)]
        args = ["--diffusion-model", A(FLUX[0])] + dec + [
            "--llm", A(FLUX[2]), "-p", prompt, "--cfg-scale", "1.0", "--steps", str(steps), "-W", str(w), "-H", str(h),
            "-t", str(icpu[1]), "-s", str(seed), "-o", A(fn)] + flags + [str(a) for a in cfg.get("args", [])]
        if be == "cpu":
            return ["taskset", "-c", icpu[0]] + UNBUF + [SD] + args
        dev = {"npu": "cpu", "gpu": "GPUOpenCL"}.get(be, "diffusion=GPUOpenCL,vae=GPUOpenCL,te=cpu")
        if re.fullmatch(r"(diffusion|vae|te)=(cpu|GPUOpenCL)(,(diffusion|vae|te)=(cpu|GPUOpenCL)){0,2}", str(req.get("sd_dev") or "")):
            dev = req["sd_dev"]  # проверка: какая часть падает на GPU (например vae=cpu)
        return a_cmd("sdcpp", "sd-cli", args + ["--backend", dev], icpu[0])
    cmd = mk(tae)
    use_fast = tae and fast
    aenv = None if be == "cpu" else a_env("sdcpp", be in ("npu", "gpu_npu"))
    log("sd-cli:", BE_NAME[be], "ядра", cmd[2], "флаги", flags, "TAEF2" if tae else "без TAEF2", "настройка", cfg)
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
    if req.get("max"):  # «максимальная скорость»: ядра, L3/LLCC/память на максимуме частоты на время картинки
        boost_on({}, False, True)
    try:
        rc, tail = run_proc(cmd, on_line, env=aenv)
        if (rc != 0 or not os.path.exists(fn)) and tae and not st["cancel"]:
            log("sd-cli с TAEF2 не вышло, повтор с полным VAE:", " | ".join(tail[-3:]))
            st["progress"] = "TAEF2 не подошёл - повтор с полным VAE…"
            use_fast = False
            vae = 13.0 * w * h / 65536
            rc, tail = run_proc(mk(False), on_line, env=aenv)
    finally:
        if req.get("max"):
            boost_restore()
    if rc != 0 or not os.path.exists(fn):
        raise RuntimeError("sd-cli код %d:\n%s" % (rc, "\n".join(tail)))
    return fn, {"X-Gen-Sec": "%.1f" % (time.time() - t), "X-Seed": str(seed), "X-Size": "%dx%d" % (w, h),
                "X-Decoder": "TAEF2 (быстрый)" if use_fast else "VAE (полный)", "X-Backend": BE_NAME[be]}


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

    def _file(self, name, d=OUT):
        # готовые картинки/звук прямо по http (без base64 через мост): /out/<имя>, поддержка Range для <audio>
        if not re.fullmatch(r"[\w .-]+", name) or name.startswith("."):
            return self._send(400, "{}")
        fn = os.path.join(d, name)
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
                                        "seed": st["seed"], "sid": st.get("sid", ""), "stream": st.get("stream"), "preview": st.get("preview", ""), "pv": st.get("pv", 0), "dl": {k: dl[k] for k in ("file", "got", "total", "err", "busy")}},
                                       ensure_ascii=False))
        elif self.path.startswith("/tts_info"):
            self._send(200, json.dumps(tts_info(), ensure_ascii=False))
        elif self.path.startswith("/out/"):
            self._file(self.path[5:].split("?")[0])
        elif self.path.startswith("/voice/"):  # образец сохранённого голоса: /voice/<имя>.wav, недавний: /voice/~<md5>.wav
            nm = urllib.parse.unquote(self.path[7:].split("?")[0])
            if nm.startswith("~"):
                self._file(nm[1:], VOICES)
            else:
                self._file(nm, SAVED)
        elif self.path.startswith("/presets"):
            self._send(200, json.dumps(presets(), ensure_ascii=False))
        elif self.path.startswith("/ref?"):  # прослушать образец голоса: /ref?src=sample | saved:<имя> | ~<md5> | /sdcard/...
            try:
                q = urllib.parse.parse_qs(self.path.split("?", 1)[1])
                fn = to_wav(ref_src((q.get("src") or [""])[0]))
                self._file(os.path.basename(fn), os.path.dirname(fn))
            except Exception as e:
                self._send(404, json.dumps({"error": "%s" % e}, ensure_ascii=False))
        elif self.path.startswith("/stream"):  # поток озвучки: /stream?off=N -> {b64: s16le с N, next, done}
            s0 = st.get("stream") or {}
            q = urllib.parse.parse_qs(self.path.split("?", 1)[1] if "?" in self.path else "")
            off = num((q.get("off") or ["0"])[0], 0)
            data = b""
            try:
                with open(os.path.join(OUT, s0.get("name") or "-"), "rb") as f:
                    f.seek(off)
                    data = f.read(1 << 19)
            except (OSError, ValueError):
                pass
            data = data[:len(data) & ~1]
            self._send(200, json.dumps({"b64": base64.b64encode(data).decode(), "off": off, "next": off + len(data),
                                        "done": bool(s0.get("done")), "err": s0.get("err", ""), "name": s0.get("name", "")}))
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
        if self.path in ("/preset_save", "/preset_del", "/export"):
            try:
                nm = str(req.get("name") or "").strip()
                if self.path == "/export":  # готовый звук / картинка -> /sdcard/Download/Fold2AI
                    if not re.fullmatch(r"(tts|flux)_[\w.-]+\.(wav|png)", nm) or not os.path.isfile(os.path.join(OUT, nm)):
                        raise ValueError("нет файла " + nm)
                    os.makedirs(EXPORT, exist_ok=True)
                    shutil.copyfile(os.path.join(OUT, nm), os.path.join(EXPORT, nm))
                    return self._send(200, json.dumps({"path": EXPORT + "/" + nm}, ensure_ascii=False))
                if not re.fullmatch(VNAME, nm):
                    raise ValueError("имя: буквы, цифры, пробел, - _ (до 40)")
                fn = os.path.join(PRESETS, nm + ".json")
                if self.path == "/preset_save":
                    os.makedirs(PRESETS, exist_ok=True)
                    with open(fn + ".tmp", "w") as f:
                        json.dump(req.get("data") or {}, f, ensure_ascii=False, indent=1)
                    os.replace(fn + ".tmp", fn)
                elif os.path.exists(fn):
                    os.remove(fn)
                return self._send(200, json.dumps(presets(), ensure_ascii=False))
            except Exception as e:
                return self._send(400, json.dumps({"error": "%s" % e}, ensure_ascii=False))
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
                    got = voice_save(req)
                    return self._send(200, json.dumps(dict(tts_info(), got=got), ensure_ascii=False))
                else:
                    voice_del(req.get("name") or "")
                return self._send(200, json.dumps(tts_info(), ensure_ascii=False))
            except Exception as e:
                return self._send(400, json.dumps({"error": "%s" % e}, ensure_ascii=False))
        job = {"/tts": (do_tts, "audio/wav"), "/image": (do_image, "image/png"), "/asr": (do_asr, "text/plain")}.get(self.path)
        if not job:
            return self._send(404, "{}")
        if not work.acquire(timeout=90 if st["busy"] == "prep" else 0.05):  # подготовка голоса - подождать её
            return self._send(409, "занято: " + st["busy"], "text/plain; charset=utf-8")
        try:
            st.update(busy=self.path[1:], cancel=False, t0=time.time(), eta=None, progress="", parts=[], nparts=0, preview="",
                      stream=None, sid=str(req.get("sid") or "")[:40])  # sid - чей это запрос: плеер не возьмёт чужие фразы/поток
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
