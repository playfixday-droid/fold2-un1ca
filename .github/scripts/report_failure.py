#!/usr/bin/env python3
# При ошибке сборки создаёт issue с найденными ошибками и концом лога (логи Actions без входа не читаются).
# Та же ошибка (workflow, job, шаг) уже есть в открытом issue - добавляет туда комментарий, а не новый issue.
import json, os, re, time, urllib.request

env = os.environ
repo, run_id, attempt = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT", "1")
api = env.get("GITHUB_API_URL", "https://api.github.com")
hdr = {"Authorization": "Bearer " + env["GH_TOKEN"], "Accept": "application/vnd.github+json",
       "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "f2q-build"}

def call(method, url, data=None):
    req = urllib.request.Request(url, method=method, headers=hdr,
                                 data=None if data is None else json.dumps(data).encode())
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}

BAD = ("failure", "timed_out", "cancelled")

def failed_step():
    """Имя упавшего шага по API. Итог шага API показывает с задержкой - поэтому несколько попыток;
    job ищется по имени раннера (точно эта копия job, в том числе в matrix), затем по JOB_NAME."""
    runner = env.get("RUNNER_NAME", "")
    last = None
    for delay in (0, 5, 10, 20):
        time.sleep(delay)
        jobs = call("GET", f"{api}/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")["jobs"]
        mine = [j for j in jobs if runner and j.get("runner_name") == runner and j.get("status") != "completed"] \
            or [j for j in jobs if j["name"] == job_name]
        if not mine:
            continue
        steps = mine[0].get("steps", [])
        bad = [s["name"] for s in steps if s.get("conclusion") in BAD]
        if bad:
            return bad[0]
        # итог ещё не обновился: последний начатый шаг перед этим (Report failure)
        started = [s["name"] for s in steps if s.get("started_at") and s.get("conclusion") != "skipped"
                   and not s["name"].lower().startswith("report failure")]
        last = started[-1] + " (?)" if started else last
    return last or "?"

job_name, step = env.get("JOB_NAME", "?"), "?"
try:
    step = failed_step()
except Exception as e:
    step = f"? ({e})"

log_path = os.path.join(env["GITHUB_WORKSPACE"], "build.log")
text = open(log_path, errors="replace").read() if os.path.exists(log_path) else ""
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
lines = text.splitlines()
pat = re.compile(r"error:|\bERROR\b|ABORT|FAILED|Error \d|No such file|not found|Traceback|patch failed|does not apply|E: ")
errs = [l for l in lines if pat.search(l)][:80]
marks = [l for l in lines if l.startswith("### ")][-5:]
if step.startswith("?") and marks:
    step = marks[-1][4:].strip()

run_url = f"{env.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{run_id}"
body = (f"Run: {run_url}\n"
        f"Job: `{job_name}`, шаг: `{step}`\n\nПоследние этапы:\n```\n" + "\n".join(marks) + "\n```\n"
        "\nСтроки с ошибками:\n```\n" + "\n".join(errs)[-15000:] + "\n```\n"
        "\nКонец лога:\n```\n" + "\n".join(lines[-300:])[-40000:] + "\n```\n")
# метка для поиска повторов: workflow + job + шаг (без номера сборки)
key = f"<!-- f2q-failure: {env.get('GITHUB_WORKFLOW', '?')} / {job_name} / {re.sub(r' [(][?].*$', '', step)} -->"

dup = None
try:
    for page in (1, 2, 3):
        issues = call("GET", f"{api}/repos/{repo}/issues?state=open&per_page=100&page={page}")
        dup = next((i for i in issues if "pull_request" not in i and key in (i.get("body") or "")), None)
        if dup or len(issues) < 100:
            break
except Exception as e:
    print("поиск повторов не удался:", e)

if dup:
    c = call("POST", f"{api}/repos/{repo}/issues/{dup['number']}/comments",
             {"body": (f"Снова: сборка #{env.get('GITHUB_RUN_NUMBER', '?')}\n" + body)[:65000]})
    print("та же ошибка уже открыта - комментарий:", c.get("html_url"))
else:
    title = f"Сборка #{env.get('GITHUB_RUN_NUMBER', '?')}: ошибка ({job_name} / {step})"
    issue = call("POST", f"{api}/repos/{repo}/issues", {"title": title[:250], "body": (key + "\n" + body)[:65000]})
    print("issue:", issue.get("html_url"))
