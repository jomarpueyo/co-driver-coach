"""Live evaluation of the race engineer (calls Claude Haiku: needs the API key, costs a few cents).
30 questions: 20 mid-drive (the voice log of 2026-10-20 with Whisper's confidence, plus common ones) on
the Vivace fixture, and 10 review questions on the 7-lap analysis, asked with the review tools and
again with the whole analysis in the prompt. Prints every answer, then: the share answered locally,
answers with numbers that aren't in the data, drive answer time (p50), and review input tokens.

Usage: python -I tools/engineer_eval.py [--drive-only | --review-only]
"""
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engineer as E  # noqa: E402
from test_engineer_local import drive_data, load  # noqa: E402

DRIVE = [("Radio check.", -0.2), ("My test, one, two, three.", -0.257), ("Sport mode.", -0.133), ("Guard image.", -0.391),
         ("Do I have car damage?", -0.036), ("A card average again, any?", -0.648), ("What you win, girl?", -0.582),
         ("I remember that.", -0.667), ("Close the car.", -0.425), ("How is the car?", -0.06), ("How are the brakes?", -0.1),
         ("How much fuel?", -0.1), ("How was the last lap?", -0.1), ("What's my best?", -0.1), ("How am I doing?", -0.1),
         ("How was that corner?", -0.1), ("Am I ready for a good run?", -0.1), ("More front bias.", -0.1),
         ("Where am I losing time this lap?", -0.2), ("Should I brake earlier for the hairpin?", -0.2)]
REVIEW = ["Give me a debrief.", "Where did lap 4 lose time?", "Compare lap 1 with my best lap.", "What was my worst corner?",
          "How consistent was I?", "What about turn 7?", "What should I work on?", "Tell me about corner 48.",
          "Which lap had the best second sector?", "How far off the theoretical best was I?"]

usage = []


def log_usage(out, secs, kind):
    u = out.get("usage") or {}
    usage.append({"kind": kind, "in": (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0),
                  "uncached": u.get("input_tokens") or 0, "read": u.get("cache_read_input_tokens") or 0,
                  "write": u.get("cache_creation_input_tokens") or 0, "out": u.get("output_tokens") or 0, "secs": secs})


E.log_usage = log_usage
E.voice_log = lambda rec: None


def ask(q, mode, data, logprob=None):
    E.LAST_HEARD.update(text=q, t=time.time(), logprob=logprob)
    n0 = len(usage)
    t0 = time.time()
    text, source, actions = E.answer({"type": "ask", "question": q, "mode": mode, "data": data})
    secs = time.time() - t0
    calls = usage[n0:]
    # cost in input-token equivalents (Haiku prices: cache write 1.25x, cache read 0.1x, output 5x)
    cost = sum(c["uncached"] + 1.25 * c["write"] + 0.1 * c["read"] + 5 * c["out"] for c in calls)
    return {"q": q, "a": text, "source": source, "secs": round(secs, 2), "calls": len(calls), "cost": round(cost),
            "in": sum(c["in"] for c in calls), "uncached": sum(c["uncached"] for c in calls), "actions": actions}


def main():
    if not E.API_KEY:
        sys.exit("no API key (ANTHROPIC_API_KEY or tools/engineer_config.json)")
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    rows = []
    if only != "--review-only":
        print("== mid-drive")
        for q, lp in DRIVE:
            d = drive_data()
            E.radio["turns"], E.radio["t"] = [], 0  # each question on its own
            r = ask(q, "drive", d, lp)
            r["bad"] = E.unsupported_numbers(r["a"], E.focus_drive(q, d), q) if not r["actions"] else []
            rows.append(dict(r, mode="drive"))
            print("%-42s %-16s %5.2fs  %s%s" % (q, r["source"], r["secs"], r["a"], ("  [numbers? %s]" % r["bad"]) if r["bad"] else ""))
    if only != "--drive-only":
        d = load("review_7laps.json")
        for tools in (True, False):
            E.CONFIG["review_tools"] = tools
            E.history["key"] = None
            print("== review, %s" % ("tools and a brief" if tools else "the whole analysis in the prompt"))
            for q in REVIEW:
                r = ask(q, "review", d)
                r["bad"] = E.unsupported_numbers(r["a"], d, q)
                rows.append(dict(r, mode="review", tools=tools))
                print("%-42s %-14s %5.2fs %d calls %6d in, cost %5d  %s%s" % (q, r["source"], r["secs"], r["calls"], r["in"], r["cost"],
                                                                               r["a"][:300], ("  [numbers? %s]" % r["bad"]) if r["bad"] else ""))
        E.CONFIG["review_tools"] = False
    drive = [r for r in rows if r["mode"] == "drive"]
    print("\n== summary")
    if drive:
        local = [r for r in drive if r["source"] == "local"]
        api = [r["secs"] for r in drive if r["source"] != "local"]
        print("drive: %d of %d answered locally (%.0f%%); time p50 %.2f s overall, %.2f s for Haiku answers; %d with numbers not in the data"
              % (len(local), len(drive), 100 * len(local) / len(drive), statistics.median(r["secs"] for r in drive),
                 statistics.median(api) if api else 0, sum(1 for r in drive if r["bad"])))
    for tools in (True, False):
        rv = [r for r in rows if r["mode"] == "review" and r.get("tools") == tools]
        if rv:
            print("review %-6s: input tokens per question mean %d, cost for the %d questions %d input-token equivalents, time p50 %.2f s, %d with numbers not in the data"
                  % ("tools" if tools else "full", statistics.mean(r["in"] for r in rv), len(rv), sum(r["cost"] for r in rv),
                     statistics.median(r["secs"] for r in rv), sum(1 for r in rv if r["bad"])))
    out = os.path.join(HERE, "tests", "eval_last.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1)
    print("rows written to", out)


if __name__ == "__main__":
    main()
