#!/usr/bin/env python3
# Выкладывает результат в Releases: AP для Odin частями < 2 ГБ (лимит GitHub на файл), ядра, SHA256SUMS.
# Использование: release.py <odin_dir> <kernel_dir> <notes_file>
import hashlib, http.client, json, os, sys, time, urllib.error, urllib.parse, urllib.request

env = os.environ
repo, tok = env["GITHUB_REPOSITORY"], env["GH_TOKEN"]
api = env.get("GITHUB_API_URL", "https://api.github.com")
odin_dir, kernel_dir, notes_file = sys.argv[1:4]
PART = 1900 * 1024 * 1024
hdr = {"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json",
       "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "f2q-build"}

def call(method, url, data=None):
    req = urllib.request.Request(url, method=method, headers=hdr,
                                 data=None if data is None else json.dumps(data).encode())
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}

tag = f"f2q-{env['GITHUB_RUN_NUMBER']}"
meta = {"name": f"f2q One UI 8 — сборка {env['GITHUB_RUN_NUMBER']}", "body": open(notes_file).read(), "prerelease": True}
# Повторный запуск (Re-run) того же run number: релиз с этим тегом уже есть (часть файлов могла не загрузиться) -
# дозагружаем в него, а не падаем на 422 при создании
try:
    rel = call("GET", f"{api}/repos/{repo}/releases/tags/{tag}")
    rel = call("PATCH", f"{api}/repos/{repo}/releases/{rel['id']}", meta)
    print("release (уже был, дозагружаю):", rel["html_url"])
except urllib.error.HTTPError as e:
    if e.code != 404:
        raise
    rel = call("POST", f"{api}/repos/{repo}/releases", dict(meta, tag_name=tag, target_commitish=env["GITHUB_SHA"]))
    print("release", rel["html_url"])
rid = rel["id"]
# адрес загрузки - из ответа API (uploads.github.com или свой у GitHub Enterprise)
up = urllib.parse.urlsplit(rel["upload_url"].split("{")[0])

def upload(name, path, off=0, size=None):
    size = os.path.getsize(path) - off if size is None else size
    for attempt in range(1, 4):
        for a in call("GET", f"{api}/repos/{repo}/releases/{rid}/assets?per_page=100"):
            if a["name"] == name:
                call("DELETE", f"{api}/repos/{repo}/releases/assets/{a['id']}")
        h = hashlib.sha256()
        try:
            c = http.client.HTTPSConnection(up.netloc, timeout=600)
            c.putrequest("POST", f"{up.path}?name={urllib.parse.quote(name)}")
            for k, v in hdr.items():
                c.putheader(k, v)
            c.putheader("Content-Type", "application/octet-stream")
            c.putheader("Content-Length", str(size))
            c.endheaders()
            with open(path, "rb") as f:
                f.seek(off)
                left = size
                while left:
                    b = f.read(min(8 << 20, left))
                    if not b:  # файл короче, чем обещали в Content-Length: без этого - вечный цикл
                        raise IOError(f"{path}: файл кончился раньше, недостаёт {left} байт")
                    h.update(b); c.send(b); left -= len(b)
            r = c.getresponse(); body = r.read()
            if r.status in (200, 201):
                print(f"  {name}: {size} байт")
                return h.hexdigest()
            print(f"  {name}: HTTP {r.status} {body[:300]!r}")
        except Exception as e:
            print(f"  {name}: {e}")
        time.sleep(20 * attempt)
    sys.exit(f"Не удалось загрузить {name}")

sums = []
ap = os.path.join(odin_dir, "AP_f2q_un1ca.tar.md5")
total = os.path.getsize(ap)
full = hashlib.sha256()
with open(ap, "rb") as f:
    for b in iter(lambda: f.read(8 << 20), b""):
        full.update(b)
sums.append(f"{full.hexdigest()}  AP_f2q_un1ca.tar.md5")
if total <= PART:
    upload("AP_f2q_un1ca.tar.md5", ap)
else:
    n = 0
    for off in range(0, total, PART):
        name = f"AP_f2q_un1ca.tar.md5.part{n:02d}"
        sums.append(f"{upload(name, ap, off, min(PART, total - off))}  {name}")
        n += 1
for k in sorted(os.listdir(odin_dir)):  # BOOT_noroot_f2q.tar.md5, Magisk-*.apk и т.п.
    p = os.path.join(odin_dir, k)
    if os.path.isfile(p) and k != "AP_f2q_un1ca.tar.md5":
        sums.append(f"{upload(k, p)}  {k}")
for k in sorted(os.listdir(kernel_dir)):
    p = os.path.join(kernel_dir, k)
    if os.path.isfile(p):
        sums.append(f"{upload('kernel-' + k, p)}  kernel-{k}")
open("SHA256SUMS", "w").write("\n".join(sums) + "\n")
upload("SHA256SUMS", "SHA256SUMS")
print("готово:", rel["html_url"])
