"""Publish build diagnostics where they can be read without a GitHub session.

Channels, in order of usefulness:
1. ``::error::`` workflow commands -> annotations on this job's check run,
   readable through the public check-runs annotations API.
2. A PATCH of this job's check run ``output.summary`` -> full extraction, readable
   through the public check-runs API.
3. ``$GITHUB_STEP_SUMMARY`` -> convenient, but rendered only for signed-in viewers.

Never fails the step: publishing problems are downgraded to warnings.
"""

import json
import os
import re
import sys
import urllib.request

API = "https://api.github.com"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
SWIFT_ERROR = re.compile(r"\.swift:\d+:\d+: error: ")
FALLBACK = re.compile(r"ENOSPC|No space left|Traceback|fatal error|FAILED:|error:", re.I)


def api(method, path, payload, token):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "User-Agent": "build-diagnostics",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def escape(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def extract(log_path):
    """Return (diagnostics, tail) from a build log."""
    if not os.path.exists(log_path):
        return [], ""
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        raw = ANSI.sub("", handle.read())
    lines = raw.splitlines()

    diagnostics = []
    seen = set()
    for line in lines:
        if SWIFT_ERROR.search(line):
            stripped = line.strip()
            if stripped not in seen:
                seen.add(stripped)
                diagnostics.append(stripped)

    if not diagnostics:
        for line in lines[-4000:]:
            if FALLBACK.search(line):
                stripped = line.strip()
                if stripped and stripped not in seen:
                    seen.add(stripped)
                    diagnostics.append(stripped)
        diagnostics = diagnostics[-40:]

    return diagnostics, "\n".join(lines[-100:])


def render(diagnostics, tail, run_id):
    summary = ["## Build diagnostics (run %s)" % run_id, ""]
    if not os.path.exists(os.environ.get("BUILD_LOG", "build.log")):
        summary.append("`build.log` was not produced (failure before the Build step).")
        return "\n".join(summary)
    if diagnostics:
        summary += ["### Unique diagnostics (%d)" % len(diagnostics), "```"]
        summary += diagnostics[:200]
        summary += ["```"]
    else:
        summary.append("No `error:` diagnostics matched in the log.")
    if tail:
        summary += ["", "### Tail of the log", "```", tail, "```"]
    text = "\n".join(summary)
    if len(text) > 60000:
        text = text[:60000] + "\n...(truncated)"
    return text


def publish_check_run_summary(text, run_id, check_name, token):
    sha = os.environ.get("GITHUB_SHA")
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not (token and sha and repo and check_name):
        return "skipped (missing token/sha/check name)"
    runs = api("GET", "/repos/%s/commits/%s/check-runs?per_page=100" % (repo, sha), None, token)
    match = next(
        (item for item in runs.get("check_runs", []) if item.get("name") == check_name), None
    )
    if not match:
        return "own check run %r not found" % check_name
    api(
        "PATCH",
        "/repos/%s/check-runs/%d" % (repo, match["id"]),
        {"output": {"title": "Build diagnostics, run %s" % run_id, "summary": text}},
        token,
    )
    return "check run %d updated" % match["id"]


def main():
    log_path = os.environ.get("BUILD_LOG", "build.log")
    run_id = os.environ.get("RUN_ID", os.environ.get("GITHUB_RUN_ID", "?"))
    check_name = os.environ.get("CHECK_NAME", "")

    diagnostics, tail = extract(log_path)
    text = render(diagnostics, tail, run_id)

    # 1. Annotations on this check run: readable without a session.
    for line in diagnostics[:50]:
        print("::error::" + escape(line))

    # 2. Full extraction on this check run's output.summary: readable via the API.
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    try:
        print("check-run summary:", publish_check_run_summary(text, run_id, check_name, token))
    except Exception as exc:  # publishing must never fail the job
        print("::warning::check-run summary not published: %s" % exc)

    # 3. The job summary, for signed-in viewers.
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        try:
            with open(step_summary, "a", encoding="utf-8") as handle:
                handle.write(text + "\n")
        except OSError as exc:
            print("::warning::job summary not written: %s" % exc)

    return 0


if __name__ == "__main__":
    sys.exit(main())
