#!/usr/bin/env python3
"""Context-layout eval. Checks that moving learnings out of the system prompt into the first
user turn (and adding a past-meeting brief there) does NOT regress question quality, and that a
brief produces good follow-ups. Three arms on the base cases:
  A_old   = base prompt + learnings in SYSTEM (the shipped-before layout)
  B_moved = base in system, learnings in first USER turn, empty brief (isolates the move)
  C_brief = base in system, brief + learnings in first user turn (the new feature)
Plus follow-up cases run on C to show the brief earns a follow-up, and B to show it can't.
Run: python3 eval_context.py"""
import json, subprocess, statistics, os

CLAUDE = os.path.expanduser("~/.local/bin/claude")
HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = "sonnet"
BASE = open(f"{HERE}/prompt_v4.txt").read()

def learnings_block():
    path = os.path.expanduser("~/remark/learnings.md")
    liked, avoid = [], []
    try:
        for raw in open(path):
            s = raw.strip()
            if s.startswith("- [like]"): liked.append(s[8:].strip())
            elif s.startswith("- [avoid]"): avoid.append(s[9:].strip())
    except FileNotFoundError:
        return ""
    out = ""
    if liked: out += "\n\nQuestions I liked before — match this taste:\n" + "\n".join("• " + x for x in liked[-12:])
    if avoid: out += "\n\nQuestions I did NOT want — never ask like these:\n" + "\n".join("• " + x for x in avoid[-8:])
    return out

LEARN = learnings_block()

# A representative brief, as ContextStore.brief() would render it.
BRIEF = """What I know from past meetings (use only if it fits what's being said now, never force it):
Recurring topics: metrics service, feature-flag rollout, request attribution, cache invalidation
Meeting types seen before: architecture review, product strategy discussion
Open threads from earlier meetings (ask a follow-up only if the same thing resurfaces now):
- Dropping auto-instrumentation might cost per-request attribution — was that confirmed? (last came up Nov 19)
- Onboarding shipped to everyone with no staged rollback plan (last came up Nov 20)"""

BASE_CASES = [
    {"id":"service-reuse","transcript":"For the new export feature we're spinning up a separate worker service with its own queue, instead of adding it to the existing API.",
     "ideal":"FIRE: simpler path — why a separate worker service instead of a background job in the existing API?"},
    {"id":"cache-reimport","transcript":"On plan change we wipe the user's cache and refetch everything. New records get a dedupe check; activity events don't.",
     "ideal":"FIRE: consequence — every plan change refetches all events and can duplicate them; is that intended?"},
    {"id":"launch-rollout","transcript":"We're shipping the new onboarding to everyone next week for the marketing campaign. Conversion was up twelve percent in the beta so we're good to go.",
     "ideal":"FIRE: unsourced number or staged-vs-all — 12% on how many users, or stage with rollback?"},
    {"id":"ts-vs-go","transcript":"Let's build the metrics service in TypeScript, not Go, so the frontend and backend can share types. We lose the APM-style auto-instrumentation but that's fine.",
     "ideal":"FIRE: tradeoff — is losing auto-instrumentation actually fine, or does it cost per-request attribution?"},
    {"id":"routine-status","transcript":"Quick status from me: the CLI release went out Tuesday, docs are updated, and I'm picking up the webhook task next. No blockers.",
     "ideal":"SILENT: routine status. Correct output is '-'."},
    {"id":"vague-metric","transcript":"The observability pipeline is way faster now after the batching change. Latency dropped a lot in testing.",
     "ideal":"FIRE: unsourced metric — dropped from what to what, measured how, at what load?"},
]

# Follow-up cases: the brief makes a prior thread relevant to what's being said now.
FOLLOWUP_CASES = [
    {"id":"fu-attribution","transcript":"Okay, the metrics service is basically done. We wired up per-request timing and it's writing to the dashboard.",
     "ideal":"FIRE follow-up: earlier we worried dropping auto-instrumentation would cost per-request attribution — do these timings actually cover it, or is attribution still partial?"},
    {"id":"fu-silent","transcript":"Small one from me, I merged the lint config bump and refreshed the README screenshots.",
     "ideal":"SILENT: routine even with a profile. Correct output is '-'."},
]

JUDGE_SYS = """You grade a meeting copilot that whispers ONE question a senior engineer could ask right now, or stays silent (outputs "-"). You get what was said, a note on the ideal response, and the copilot's output (format "gap | question", or "-").
Score each 1-5 (5 best):
- ask_it: would this engineer actually want to ask this out loud, right now? Sharp and welcome, not pedantic/obvious/process-y. If output is "-": 5 if silence was right, 1 if there was a clear question worth asking.
- grounded: specific to what was actually said, not generic best practice. For "-", score 3.
- sharp: targets a real gap that changes what the group does. For "-", score 3.
- clean: reads like a person said it out loud — plain words, tight, no slop, no em dashes. For "-", score 5.
Return ONLY JSON: {"ask_it":n,"grounded":n,"sharp":n,"clean":n,"verdict":"<=12 words"}"""

def claude(system, prompt):
    try:
        r = subprocess.run([CLAUDE,"-p","--model",MODEL,"--setting-sources","","--system-prompt",system,prompt],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=150)
        return (r.stdout or r.stderr).strip()
    except Exception as e:
        return f"ERROR: {e}"

def judge(transcript, ideal, output):
    raw = claude(JUDGE_SYS, f"What was said:\n{transcript}\n\nIdeal: {ideal}\n\nCopilot output:\n{output}\n\nGrade it.")
    try:
        return json.loads(raw[raw.index("{"):raw.rindex("}")+1])
    except Exception:
        return {"ask_it":0,"grounded":0,"sharp":0,"clean":0,"verdict":"parse-fail: "+raw[:80]}

def run_arm(name, system, user_prefix, cases):
    print(f"\n########## {name} ##########")
    rows = []
    for c in cases:
        out = claude(system, user_prefix + "Latest:\n" + c["transcript"])
        j = judge(c["transcript"], c["ideal"], out)
        rows.append({"case":c["id"],"output":out,**j})
        print(f"[{name}] {c['id']}: {out!r}  (ask={j.get('ask_it')} g={j.get('grounded')} s={j.get('sharp')} c={j.get('clean')})")
    return rows

results = {}
results["A_old"]   = run_arm("A_old  (learnings in system)", BASE + LEARN, "", BASE_CASES)
results["B_moved"] = run_arm("B_moved(learnings in user turn)", BASE, LEARN + "\n\n", BASE_CASES)
results["C_brief"] = run_arm("C_brief(brief+learnings in user turn)", BASE, BRIEF + "\n\n" + LEARN + "\n\n", BASE_CASES)
# follow-up value: C has the brief, B does not
results["C_followup"] = run_arm("C_followup(with brief)", BASE, BRIEF + "\n\n" + LEARN + "\n\n", FOLLOWUP_CASES)
results["B_followup"] = run_arm("B_followup(no brief)", BASE, LEARN + "\n\n", FOLLOWUP_CASES)

print("\n===================== SCORECARD =====================")
def mean(rows,k): return round(statistics.mean([(r.get(k) or 0) for r in rows]),2)
for name, rows in results.items():
    a,g,s,c = mean(rows,"ask_it"),mean(rows,"grounded"),mean(rows,"sharp"),mean(rows,"clean")
    print(f"{name:28s}: ask_it={a}  grounded={g}  sharp={s}  clean={c}  OVERALL={round((a+g+s+c)/4,2)}")
json.dump(results, open(f"{HERE}/results_context.json","w"), indent=2)
print("\nsaved -> evals/results_context.json")
