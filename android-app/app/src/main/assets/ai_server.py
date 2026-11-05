#!/usr/bin/env python3
# Fold2 AI: сервер в Debian на 127.0.0.1:8082 - клон голоса (Qwen3-TTS 0.6B Base, CPU) и картинки (FLUX.2 klein 4B,
# stable-diffusion.cpp). Модель TTS грузится при первом запросе и выгружается перед картинкой (память).
import gc, json, os, subprocess, threading, time, traceback
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

M = "/sdcard/models"; OUT = M + "/out"
TTS_DIR = M + "/qwen3-tts-0.6b-base"
SD = "/opt/stable-diffusion.cpp/build/bin/sd-cli"
FLUX = [M + "/flux2/flux-2-klein-4b-Q4_0.gguf", M + "/flux2/flux2-vae.safetensors", M + "/flux2/Qwen3-4B-Q4_0.gguf"]
SAMPLE = OUT + "/ref_clone.wav"
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


def do_tts(req):
    text = (req.get("text") or "").strip()
    if not text:
        raise ValueError("пустой текст")
    if not os.path.exists(SAMPLE) and not req.get("ref_audio"):
        subprocess.run(["curl", "-fsSL", "-o", SAMPLE,
                        "https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-TTS-Repo/clone.wav"], check=True)
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
                                      voice_clone_prompt=st["prompts"][key])
    dt = time.time() - t
    import soundfile as sf
    fn = OUT + "/tts_%s.wav" % time.strftime("%Y%m%d_%H%M%S")
    sf.write(fn, wavs[0], sr)
    return fn, {"X-Gen-Sec": "%.2f" % dt, "X-Audio-Sec": "%.2f" % (len(wavs[0]) / sr)}


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
    cmd = ["taskset", "-c", "4-7", SD, "--diffusion-model", FLUX[0], "--vae", FLUX[1], "--llm", FLUX[2],
           "-p", prompt, "--cfg-scale", "1.0", "--steps", str(steps), "-W", str(w), "-H", str(h), "-t", "4",
           "-s", str(seed), "-o", fn] + sd_flags()
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
            self._send(200, json.dumps({"ok": True, "tts_loaded": st["tts"] is not None, "busy": st["busy"],
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
