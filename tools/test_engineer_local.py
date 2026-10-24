"""Offline tests for the engineer's local answers, reply checks and review tools (no network, no game):
which questions are answered without Haiku and what they say, garbled speech, replies that explain
themselves, numbers that aren't in the data, and the review lookups on a real 7-lap analysis
(tools/tests/fixtures, captured from the game with coDriverEngineer.getReviewContext).

Usage: python -I tools/test_engineer_local.py
"""
import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engineer as E  # noqa: E402

FIX = os.path.join(HERE, "tests", "fixtures")


def load(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


def drive_data():
    """The Vivace mid-drive (fixture) with the lap timer's radio state and a few recent events."""
    d = load("drive_vivace.json")
    d["speed"] = "61 mph"
    d["laps"] = {"current": {"lap": 5, "time": "0:31.20", "valid": True, "gapToBestNow": -0.21, "donePct": 52},
                 "route": {"km": 1.98, "kind": "loop", "bestEver": "1:00.31"},
                 "lastLap": {"lap": 4, "time": "1:00.83", "valid": True, "gapToBest": 0.52, "secondsAgo": 31}}
    d["recent"] = ["95 s ago: lap 3 1:01.12, +0.81 s to the best", "40 s ago: corner 3 Left at 54 mph",
                   "31 s ago: lap 4 1:00.83, +0.52 s to the best", "12 s ago: corner Hairpin Right at 29 mph, over the called 25 mph"]
    return d


# the voice log of 2026-10-20 (what Whisper heard and how sure it was) and questions drivers ask
HEARD = [("My test, one, two, three.", -0.257), ("Sport mode.", -0.133), ("Guard image.", -0.391), ("Do I have car damage?", -0.036),
         ("A card average again, any?", -0.648), ("Card image, mini-card image.", -0.617), ("What you win, girl?", -0.582),
         ("What you wearing, girl.", -0.289), ("I remember that.", -0.667), ("I'm dead.", -0.095), ("Close the car.", -0.425),
         ("How is the car?", -0.06)]


class LocalAnswers(unittest.TestCase):
    def setUp(self):
        self.d = drive_data()

    def ans(self, q, lp=None):
        return E.local_answer(q, self.d, lp)

    def test_radio_check_and_thanks(self):
        self.assertEqual(self.ans("Radio check"), "Loud and clear.")
        self.assertEqual(self.ans("My test, one, two, three."), "Loud and clear.")
        self.assertEqual(self.ans("Can you hear me?"), "Loud and clear.")
        self.assertEqual(self.ans("Thanks."), "Copy.")

    def test_garbled_speech(self):
        for q, lp in HEARD:
            if q in ("A card average again, any?", "Card image, mini-card image.", "What you win, girl?", "I remember that.", "Guard image.", "I'm dead."):
                self.assertEqual(self.ans(q, lp), "Say again?", q)
        self.assertIsNone(self.ans("Sport mode.", -0.133), "a change to the car goes to Haiku's tools")
        self.assertNotEqual(self.ans("How is the car?", -0.06), "Say again?")
        for q in ("Any advice?", "Should I pit?", "Why?", "Tips?", "Am I improving?", "How's it going?"):
            self.assertIsNone(self.ans(q), "short open question goes to Haiku: " + q)
            self.assertIsNone(self.ans(q, -0.2), "spoken clearly: " + q)
        self.d["car"]["brakes"]["front"] = 420
        self.assertEqual(self.ans("How is the car?"), "All healthy, brakes at 420, no fade.")

    def test_laps(self):
        self.assertEqual(self.ans("How was the last lap?"), "Lap 4, one oh oh point eight, five tenths off your best.")
        self.assertEqual(self.ans("What's my best?"), "Your best here is one oh oh point three.")
        self.assertEqual(self.ans("How am I doing?"), "Two tenths quicker, 52 percent in.")
        self.d["laps"]["lastLap"].update(valid=False, notCountedBecause="left the route")
        self.assertEqual(self.ans("Last lap?"), "Lap 4, one oh oh point eight, not counted: left the route.")

    def test_car(self):
        self.assertEqual(self.ans("How is the car?"), "All healthy, brakes still cold at 191 degrees.")  # 191 F is 88 C
        self.assertIn("brakes", self.ans("How are the brakes?").lower())
        self.assertEqual(self.ans("Fuel?"), "Fuel at 100 percent.")
        self.assertEqual(self.ans("Do I have car damage?"), "No real damage.")
        self.assertEqual(self.ans("What's my speed?"), "61 miles an hour.")
        self.assertEqual(self.ans("What have you changed?"), "Brake bias stock at 77 percent front.")
        d = copy.deepcopy(self.d)
        d["car"]["tyres"]["flat"] = ["FL"]
        self.assertEqual(E.local_answer("Check car", d), "Watch the puncture FL.")

    def test_haiku_questions(self):
        for q in ("How was that corner?", "Where am I losing time?", "Should I brake earlier for the hairpin?", "More front bias.",
                  "Am I faster than my best through the esses, and why?", "Traction control off."):
            self.assertIsNone(self.ans(q), q)

    def test_local_answers_have_only_data_numbers(self):
        for q in ("How is the car?", "How are the brakes?", "Fuel?", "How was the last lap?", "What's my best?", "How am I doing?",
                  "What's my speed?", "What have you changed?", "How are the tyres?", "What's the weather?"):
            a = self.ans(q)
            self.assertIsNotNone(a, q)
            self.assertEqual(E.unsupported_numbers(a, self.d, q), [], "%s -> %s" % (q, a))


class VoiceLogFixes(unittest.TestCase):
    """From the voice log of 2026-10-21: an empty damage list, follow-ups, and advice questions."""

    def test_damage_without_parts(self):
        d = drive_data()
        d["car"]["damage"] = {"level": "light", "parts": {}}
        self.assertEqual(E.local_answer("Car damage.", d), "Light damage.")
        d["car"]["damage"] = {"level": "moderate", "parts": ["front bumper", "hood"]}
        self.assertEqual(E.local_answer("Car damage.", d), "Moderate damage, front bumper, hood.")

    def test_follow_ups_go_to_haiku(self):
        d = drive_data()
        for q in ("Yes, go ahead.", "Pros and cons.", "OK", "Do it."):
            self.assertIsNone(E.local_answer(q, d, -0.1, follow_up=True), q)
        self.assertEqual(E.local_answer("Yes, go ahead.", d, -0.1), "Say again?", "with no conversation it is still a remark")
        self.assertEqual(E.local_answer("Pros, cons.", d, -0.9, follow_up=True), "Say again?", "unsure speech is still unsure")

    def test_questions_never_change_the_car(self):
        adj = {"biasShift": 0, "brakePct": 100, "ffbPct": 100, "has": {"abs": True, "tc": True, "esc": True}}
        for q in ("Should I turn off abs?", "Would sport mode help?", "Is there traction control enabled?", "Can I turn off ESC?"):
            self.assertTrue(E.Q_START.match(q.lower()), q)
            self.assertIsNone(E.offline_adjust(q, adj), q)
        for q in ("Turn off ABS.", "Can you turn off ABS?", "More front bias."):
            self.assertIsNotNone(E.offline_adjust(q, adj), q)
        calls = []

        def fake(system, messages, max_tokens=350, tools=None, tool_choice=None, **kw):
            calls.append(tool_choice)
            return {"content": [{"type": "text", "text": "It stops the wheels locking. Want it off?"}], "stop_reason": "end_turn"}
        old, key = E.haiku_call, E.API_KEY
        E.haiku_call, E.API_KEY = fake, "test"
        E.voice_log = lambda rec: None
        try:
            E.radio["turns"], E.radio["t"] = [], 0
            text, source, actions = E.answer({"question": "Should I turn off abs?", "mode": "drive", "data": {"car": {}, "adjust": adj}})
        finally:
            E.haiku_call, E.API_KEY = old, key
        self.assertEqual(actions, [])
        self.assertEqual(calls[0], {"type": "none"}, "the tools can't be called for a question")


class Checks(unittest.TestCase):
    def test_leaks(self):
        for bad in ('"Guard image" sounds like a garbled question, so I\'ll say it again.',
                    "The driver says \"I remember that,\" which is a comment, not a question.",
                    "\"Close the car\" is not a tool request I can act on, and the question is general."):
            self.assertTrue(E.leaks(bad), bad)
        self.assertEqual(E.strip_leaks("The driver asks whether to brake earlier. This is a judgement question, so at most two sentences. "
                                       "Go a touch earlier, brakes are cold."), "Go a touch earlier, brakes are cold.")
        self.assertEqual(E.strip_leaks("Brakes are cold at 191. The answer is a single short sentence."), "Brakes are cold at 191.")
        self.assertEqual(E.strip_leaks('"Guard image" sounds garbled.'), "")
        for ok in ("Loud and clear.", "Brakes at 191, no fade.", "Two tenths up on your best, keep it tidy."):
            self.assertFalse(E.leaks(ok), ok)

    def test_numbers(self):
        d = drive_data()
        self.assertEqual(E.unsupported_numbers("Brakes at 191 front, 167 rear, water 185.", d), [])
        self.assertEqual(E.unsupported_numbers("Brakes at 191, fine.", {"car": {"brakes": {"front": 190.6}}}), [])
        self.assertEqual(E.unsupported_numbers("Brakes at 420, fine.", d), ["420"])
        self.assertEqual(E.unsupported_numbers("Lap 4 was 0.31 slower than lap 3.", d), [], "a difference of two lap times")
        self.assertEqual(E.unsupported_numbers("Lap 4, two tenths off.", d), [])
        self.assertEqual(E.unsupported_numbers("You lost 3.7 seconds there.", d), ["3.7"])


class OwnVoice(unittest.TestCase):
    WORDS = ["nice_save", "brake", "brake_hard", "new_best", "caution", "slow_down", "are_you_okay", "100", "and"]

    def test_cover(self):
        self.assertEqual(E.voice_cover("Nice save!", self.WORDS), ["nice_save"])
        self.assertEqual(E.voice_cover("Brake hard, brake.", self.WORDS), ["brake_hard", "brake"])
        self.assertEqual(E.voice_cover("Are you okay?", self.WORDS), ["are_you_okay"])
        self.assertIsNone(E.voice_cover("Say again?", self.WORDS))
        self.assertIsNone(E.voice_cover("Brakes are fading.", self.WORDS))
        self.assertIsNone(E.voice_cover("", self.WORDS))
        self.assertIsNone(E.voice_cover("Nice save.", None))


class ReviewTools(unittest.TestCase):
    def setUp(self):
        self.d = load("review_7laps.json")

    def test_brief_is_small(self):
        full = len(json.dumps(self.d, separators=(",", ":")))
        brief = len(json.dumps(E.review_brief(self.d), separators=(",", ":")))
        print("\nreview prompt data: full %d bytes, brief %d bytes (%.0f%%)" % (full, brief, 100 * brief / full))
        self.assertLess(brief, full * 0.35)
        b = E.review_brief(self.d)
        self.assertEqual(len(b["laps"]["list"]), len(self.d["laps"]["laps"]))
        self.assertEqual(b["cornerIndex"][0]["id"], self.d["corners"][0]["id"])

    def test_results_are_bounded_and_right(self):
        L = self.d["laps"]
        best = L["bestLap"]
        for name, inp in (("corner_detail", {"ids": [c["id"] for c in self.d["corners"][:3]]}), ("lap_detail", {"lap": 4}),
                          ("lap_compare", {"a": 4, "b": best}), ("turn_detail", {"turn": 1}), ("lap_detail", {"lap": 99}),
                          ("corner_detail", {"ids": "x"}), ("nope", {})):
            r = E.review_tool(name, inp, self.d)
            self.assertLessEqual(len(r), E.TOOL_BYTES, name)
            json.loads(r)
        cmp_ = json.loads(E.review_tool("lap_compare", {"a": 4, "b": best}, self.d))
        lap4 = next(l for l in L["laps"] if l["lap"] == 4)
        self.assertAlmostEqual(cmp_["gap"], lap4["gapToBest"], delta=0.02)
        self.assertGreater(cmp_["turnsWhereALostMost"][0]["aLost"], 1, "lap 4 lost seconds in one turn")
        self.assertIn("whereALostVsBestLap", cmp_)
        t1 = json.loads(E.review_tool("turn_detail", {"turn": 1}, self.d))
        self.assertEqual(t1["timesByLap"], L["turns"][0]["timesByLap"])
        c = json.loads(E.review_tool("corner_detail", {"ids": [self.d["corners"][0]["id"]]}, self.d))
        self.assertEqual(c["corners"][0]["loss"], self.d["corners"][0]["loss"])

    def test_tool_loop_with_a_fake_api(self):
        calls = []

        def fake(system, messages, max_tokens=350, tools=None, tool_choice=None, cache=False, kind="drive", think=0):
            calls.append({"messages": messages, "think": think, "tool_choice": tool_choice})
            if len(calls) == 1:
                return {"content": [{"type": "tool_use", "id": "t1", "name": "lap_detail", "input": {"lap": 4}}], "stop_reason": "tool_use"}
            return {"content": [{"type": "text", "text": "Lap 4 lost most at turn 13."}], "stop_reason": "end_turn"}
        old = E.haiku_call
        E.haiku_call = fake
        try:
            text = E.review_with_tools("sys", [{"role": "user", "content": "Give me a debrief."}], self.d, "Give me a debrief.")
        finally:
            E.haiku_call = old
        self.assertEqual(text, "Lap 4 lost most at turn 13.")
        self.assertEqual(calls[0]["think"], 1024, "a debrief thinks first")
        res = calls[1]["messages"][-1]["content"][0]
        self.assertEqual(res["type"], "tool_result")
        self.assertIn("whereLostVsBestLap", res["content"])

    def test_rounds_are_capped(self):
        n = []

        def fake(system, messages, max_tokens=350, tools=None, tool_choice=None, **kw):
            n.append(tool_choice)
            if tool_choice and tool_choice.get("type") == "none":
                return {"content": [{"type": "text", "text": "Done."}], "stop_reason": "end_turn"}
            return {"content": [{"type": "tool_use", "id": "t%d" % len(n), "name": "turn_detail", "input": {"turn": 1}}], "stop_reason": "tool_use"}
        old = E.haiku_call
        E.haiku_call = fake
        try:
            self.assertEqual(E.review_with_tools("sys", [{"role": "user", "content": "q"}], self.d, "turn 1?"), "Done.")
        finally:
            E.haiku_call = old
        self.assertEqual(len(n), E.REVIEW_TOOL_ROUNDS + 1)


if __name__ == "__main__":
    unittest.main()
