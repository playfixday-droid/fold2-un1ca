#!/usr/bin/env python3
# При ошибке сборки создаёт issue с найденными ошибками и концом лога (логи Actions без входа не читаются).
import json, os, re, urllib.request

env = os.environ
repo, run_id, attempt = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT", "1")
api = env.get("GITHUB_API_URL", "https://api.github.com")
hdr = {"Authorization": "Bearer " + env["GH_TOKEN"], "Accept": "application/vnd.github+json",
       "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "f2q-build"}

def call(method, url, data=None):
    req = urllib.request.Request(url, method=method, headers=hdr,
                                 data=None if data is None else json.dumps(data).encode())
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

job_name, step = env.get("JOB_NAME", "?"), "?"
try:
    jobs = call("GET", f"{api}/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=50")["jobs"]
    for j in jobs:
        if j["name"] == job_name:
            bad = [s["name"] for s in j.get("steps", []) if s.get("conclusion") == "failure"]
            step = bad[0] if bad else step
except Exception as e:
    step = f"? ({e})"

log_path = os.path.join(env["GITHUB_WORKSPACE"], "build.log")
text = open(log_path, errors="replace").read() if os.path.exists(log_path) else ""
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
lines = text.splitlines()
pat = re.compile(r"error:|\bERROR\b|ABORT|FAILED|Error \d|No such file|not found|Traceback|patch failed|does not apply|E: ")
errs = [l for l in lines if pat.search(l)][:80]
marks = [l for l in lines if l.startswith("### ")][-5:]

body = (f"Run: {env.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{run_id}\n"
        f"Job: `{job_name}`, шаг: `{step}`\n\nПоследние этапы:\n```\n" + "\n".join(marks) + "\n```\n"
        "\nСтроки с ошибками:\n```\n" + "\n".join(errs)[-15000:] + "\n```\n"
        "\nКонец лога:\n```\n" + "\n".join(lines[-300:])[-40000:] + "\n```\n")
title = f"Сборка #{env.get('GITHUB_RUN_NUMBER', '?')}: ошибка ({job_name} / {step})"
issue = call("POST", f"{api}/repos/{repo}/issues", {"title": title[:250], "body": body[:65000]})
print("issue:", issue.get("html_url"))
