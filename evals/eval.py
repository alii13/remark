#!/usr/bin/env python3
"""Remark question-quality eval. Runs each prompt variant over realistic cases,
grades each output with an LLM judge on 'would I actually ask this?', prints a
scorecard. Run: python3 eval.py"""
import json, subprocess, statistics, os

CLAUDE = os.path.expanduser("~/.local/bin/claude")
HERE = os.path.dirname(os.path.abspath(__file__))
GEN_MODEL = "sonnet"
JUDGE_MODEL = "sonnet"

CASES = [
    {"id": "service-reuse",
     "transcript": "For the new export feature we're spinning up a separate worker service with its own queue, instead of adding it to the existing API.",
     "ideal": "FIRE: simpler path — why a separate worker service instead of a background job in the existing API?"},
    {"id": "cache-reimport",
     "transcript": "On plan change we wipe the user's cache and refetch everything. New records get a dedupe check; activity events don't.",
     "ideal": "FIRE: consequence — every plan change refetches all events and can duplicate them; is that intended?"},
    {"id": "launch-rollout",
     "transcript": "We're shipping the new onboarding to everyone next week for the marketing campaign. Conversion was up twelve percent in the beta so we're good to go.",
     "ideal": "FIRE: unsourced number or staged-vs-all — 12% on how many users, or should we stage with a rollback?"},
    {"id": "ts-vs-go",
     "transcript": "Let's build the metrics service in TypeScript, not Go, so the frontend and backend can share types. We lose the APM-style auto-instrumentation but that's fine.",
     "ideal": "FIRE: tradeoff — is losing auto-instrumentation actually fine, or does that cost the per-request attribution we need?"},
    {"id": "routine-status",
     "transcript": "Quick status from me: the CLI release went out Tuesday, docs are updated, and I'm picking up the webhook task next. No blockers.",
     "ideal": "SILENT: routine status, nothing to probe. A question here would be pedantic. Correct output is '-'."},
    {"id": "vague-metric",
     "transcript": "The observability pipeline is way faster now after the batching change. Latency dropped a lot in testing.",
     "ideal": "FIRE: unsourced metric — dropped from what to what, measured how, at what load?"},
]

JUDGE_SYS = """You grade a meeting copilot that whispers ONE question a senior engineer could ask right now, or stays silent (outputs "-"). You get what was said, a note on the ideal response, and the copilot's output (format "gap | question", or "-").

Score each 1-5 (5 best):
- ask_it: would this engineer actually want to ask this out loud, right now, in front of the room? Sharp and welcome, not pedantic, obvious, or process-y. If output is "-": 5 if staying silent was right here, 1 if there was a clear question worth asking.
- grounded: specific to what was actually said (names the real thing), not generic best practice. For "-", score 3.
- sharp: targets a real gap that would change what the group does or decides. For "-", score 3.
- clean: reads like a person said it out loud — plain words, concrete, no filler, no jargon-slop, no em dashes, tight. For "-", score 5.

Return ONLY a JSON object, nothing else:
{"ask_it":n,"grounded":n,"sharp":n,"clean":n,"verdict":"<=12 words why"}"""

def claude(system, prompt, model):
    try:
        r = subprocess.run([CLAUDE, "-p", "--model", model, "--setting-sources", "",
                            "--system-prompt", system, prompt],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=150)
        return (r.stdout or r.stderr).strip()
    except Exception as e:
        return f"ERROR: {e}"

def judge(transcript, ideal, output):
    prompt = f"What was said:\n{transcript}\n\nIdeal response: {ideal}\n\nCopilot output:\n{output}\n\nGrade it."
    raw = claude(JUDGE_SYS, prompt, JUDGE_MODEL)
    try:
        return json.loads(raw[raw.index("{"):raw.rindex("}")+1])
    except Exception:
        return {"ask_it": 0, "grounded": 0, "sharp": 0, "clean": 0, "verdict": "parse-fail: " + raw[:100]}

variants = {"v4": open(f"{HERE}/prompt_v4.txt").read()}
results = {}
for vname, vprompt in variants.items():
    print(f"\n########## {vname} ##########")
    rows = []
    for c in CASES:
        out = claude(vprompt, "Latest:\n" + c["transcript"], GEN_MODEL)
        j = judge(c["transcript"], c["ideal"], out)
        rows.append({"case": c["id"], "output": out, **j})
        print(f"[{vname}] {c['id']}: {out!r}")
        print(f"    ask={j.get('ask_it')} grounded={j.get('grounded')} sharp={j.get('sharp')} clean={j.get('clean')} :: {j.get('verdict')}")
    results[vname] = rows

print("\n\n===================== SCORECARD =====================")
def mean(rows, k): return round(statistics.mean([(r.get(k) or 0) for r in rows]), 2)
for vname, rows in results.items():
    a, g, s, c = mean(rows, "ask_it"), mean(rows, "grounded"), mean(rows, "sharp"), mean(rows, "clean")
    print(f"{vname}: ask_it={a}  grounded={g}  sharp={s}  clean={c}  OVERALL={round((a+g+s+c)/4,2)}")
json.dump(results, open(f"{HERE}/results.json", "w"), indent=2)
print("\nsaved -> evals/results.json")
