"""Offline tests for the race engineer's car adjustments (no network, no game, no microphone):
clamping, the simple phrases used without Haiku, the Haiku tool loop with a fake API, and the
actions in the bridge's answer file.

Usage: python -I tools/test_engineer_adjust.py
"""
import json
import os
import sys
import tempfile
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engineer as E  # noqa: E402

E.voice_log = lambda rec: None  # never write test answers into the real voice log (VOICE_LOG is fixed at import)

STOCK = {"biasShift": 0, "brakePct": 100, "ffbPct": 100, "stockFrontPct": 60.3, "frontPct": 60.3, "canBias": True, "ffbDevice": True}
# a car with electronics, as the game reports it (Vivace Ardente track)
MODES = [{"key": "comfort", "name": "Comfort"}, {"key": "sport", "name": "Sport"}, {"key": "arsenic", "name": "Arsenic"},
         {"key": "off", "name": "ESC & TC Off"}]
VIVACE = dict(STOCK, driveModes=MODES, driveMode="arsenic", launchMaxRPM=6300, targets={},
              has={"esc": True, "tc": True, "abs": True, "launch": True, "awdLock": True})


def adj(**kw):
    a = dict(STOCK)
    a.update(kw)
    return a


class FakeAPI:
    """Stands in for haiku_call: returns the queued responses in order and keeps the requests."""

    def __init__(self, *responses):
        self.responses, self.calls = list(responses), []

    def __call__(self, system, messages, max_tokens=350, tools=None, tool_choice=None, **kw):
        self.calls.append({"messages": messages, "tools": tools, "tool_choice": tool_choice})
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def tool_use(name, inp, uid="tu_1"):
    return {"type": "tool_use", "id": uid, "name": name, "input": inp}


def reply(*blocks, stop="tool_use"):
    return {"content": [b if isinstance(b, dict) else {"type": "text", "text": b} for b in blocks], "stop_reason": stop}


class Clamping(unittest.TestCase):
    def test_limits(self):
        cases = [("set_brake_bias", {"front_shift": 14}, "bias", 10, True),
                 ("set_brake_bias", {"front_shift": -30}, "bias", -10, True),
                 ("set_brake_bias", {"front_shift": 2}, "bias", 2, False),
                 ("set_brake_strength", {"percent": 150}, "brake", 110, True),
                 ("set_brake_strength", {"percent": 50}, "brake", 80, True),
                 ("set_brake_strength", {"percent": 92.5}, "brake", 92.5, False),
                 ("set_ffb_strength", {"percent": 200}, "ffb", 130, True),
                 ("set_ffb_strength", {"percent": 10}, "ffb", 60, True),
                 ("set_ffb_strength", {"percent": "90"}, "ffb", 90, False)]
        for name, inp, kind, value, limited in cases:
            acts, text, lim = E.tool_action(name, inp, STOCK)
            self.assertEqual(acts, [{"kind": kind, "value": value}], (name, inp))
            self.assertEqual(lim, limited, (name, inp))
            self.assertEqual("limited" in text, limited)

    def test_no_change(self):
        for name, inp, a in (("set_ffb_strength", {}, STOCK), ("set_ffb_strength", {"percent": "lots"}, STOCK),
                             ("set_brake_bias", {"front_shift": 2}, adj(canBias=False)), ("revert_adjustments", {}, STOCK),
                             ("rm_rf", {}, STOCK), ("set_awd_lock", {"percent": 20}, dict(VIVACE, has={"awdLock": False})),
                             ("set_drive_mode", {"mode": "sport"}, STOCK), ("set_drive_mode", {"mode": "eco"}, VIVACE),
                             ("set_launch_control", {"enabled": True}, dict(VIVACE, has={"launch": False}))):
            self.assertEqual(E.tool_action(name, inp, a)[0], [], (name, inp))
        self.assertIn("Comfort, Sport", E.tool_action("set_drive_mode", {"mode": "eco"}, VIVACE)[1])

    def test_revert_and_texts(self):
        self.assertEqual(E.tool_action("revert_adjustments", {}, adj(ffbPct=90))[0], [{"kind": "revert"}])
        self.assertEqual(E.tool_action("revert_adjustments", {}, None)[0], [{"kind": "revert"}])  # state unknown: still allowed
        self.assertEqual(E.tool_action("revert_adjustments", {}, dict(VIVACE, targets={"tc": False}))[0], [{"kind": "revert"}])
        self.assertIn("62 percent front", E.tool_action("set_brake_bias", {"front_shift": 2}, STOCK)[1])
        self.assertIn("may not feel it", E.tool_action("set_ffb_strength", {"percent": 90}, adj(ffbDevice=False))[1])


class Electronics(unittest.TestCase):
    def test_tools(self):
        t = E.tool_action
        self.assertEqual(t("set_drive_mode", {"mode": "sport"}, VIVACE)[0], [{"kind": "driveMode", "value": "sport"}])
        self.assertEqual(t("set_drive_mode", {"mode": "Arsenic mode"}, VIVACE)[0], [{"kind": "driveMode", "value": "arsenic"}])
        self.assertEqual(t("set_drive_mode", {"mode": "esc & tc off"}, VIVACE)[0], [{"kind": "driveMode", "value": "off"}])
        self.assertEqual(t("set_driver_aids", {"esc": False, "traction_control": False}, VIVACE)[0],
                         [{"kind": "esc", "value": False}, {"kind": "tc", "value": False}])
        acts, text, limited = t("set_driver_aids", {"abs": False, "esc": True}, dict(VIVACE, has={"esc": True, "abs": False}))
        self.assertEqual((acts, limited), ([{"kind": "esc", "value": True}], True))
        self.assertIn("no ABS", text)
        self.assertEqual(t("set_launch_control", {"enabled": True, "rpm": 8000}, VIVACE)[0],
                         [{"kind": "launch", "value": True}, {"kind": "launchRPM", "value": 6300}])
        self.assertEqual(t("set_awd_lock", {"percent": 80}, VIVACE)[0], [{"kind": "awdLock", "value": 60}])

    def test_phrases(self):
        def act(q, a=VIVACE):
            r = E.offline_adjust(q, a)
            return r and r[1]
        self.assertEqual(act("traction control off"), [{"kind": "tc", "value": False}])
        self.assertEqual(act("turn off the ESC"), [{"kind": "esc", "value": False}])
        self.assertEqual(act("T.C. off please"), [{"kind": "tc", "value": False}])
        self.assertEqual(act("A.B.S. on"), [{"kind": "abs", "value": True}])
        self.assertEqual(act("disable stability control"), [{"kind": "esc", "value": False}])
        self.assertEqual(act("launch control on"), [{"kind": "launch", "value": True}])
        self.assertEqual(act("launch rpm 4500"), [{"kind": "launchRPM", "value": 4500}])
        self.assertEqual(act("sport mode please"), [{"kind": "driveMode", "value": "sport"}])
        self.assertEqual(act("switch to comfort"), [{"kind": "driveMode", "value": "comfort"}])
        self.assertEqual(act("more centre lock"), [{"kind": "awdLock", "value": 10}])
        self.assertEqual(act("more center lock", dict(VIVACE, targets={"awdLock": 0.3})), [{"kind": "awdLock", "value": 40}])
        self.assertEqual(act("abs off", dict(VIVACE, has={"abs": False})), [])
        for q in ("is traction control on", "what mode am I in", "how's the launch", "sport is fun"):
            self.assertIsNone(E.offline_adjust(q, VIVACE), q)

    def test_model_view(self):
        m = E.adjust_for_model(dict(VIVACE, targets={"tc": False, "awdLock": 0.3, "driveMode": "sport"}))
        self.assertEqual(m["driveModes"], ["Comfort", "Sport", "Arsenic", "ESC & TC Off"])
        self.assertEqual(m["driveMode"], "Arsenic")
        self.assertEqual(m["awdLockPct"], 30)
        self.assertEqual(m["electronicsChanged"], {"traction control": "off", "drive mode": "Sport"})
        self.assertEqual(sorted(m["has"]), ["abs", "awdLock", "esc", "launch", "tc"])
        self.assertIn("traction control off", E.adjust_summary(dict(VIVACE, targets={"tc": False})))


class Phrases(unittest.TestCase):
    def act(self, q, a=STOCK):
        r = E.offline_adjust(q, a)
        return r and r[1]

    def test_changes(self):
        self.assertEqual(self.act("more front bias"), [{"kind": "bias", "value": 2}])
        self.assertEqual(self.act("more front bias please", adj(biasShift=2)), [{"kind": "bias", "value": 4}])
        self.assertEqual(self.act("move the bias back"), [{"kind": "bias", "value": -2}])
        self.assertEqual(self.act("more rear brake bias"), [{"kind": "bias", "value": -2}])
        self.assertEqual(self.act("FFB lighter"), [{"kind": "ffb", "value": 90}])
        self.assertEqual(self.act("F.F.B. lighter please"), [{"kind": "ffb", "value": 90}])
        self.assertEqual(self.act("make the force feedback lighter", adj(ffbPct=90)), [{"kind": "ffb", "value": 80}])
        self.assertEqual(self.act("force feedback heavier"), [{"kind": "ffb", "value": 110}])
        self.assertEqual(self.act("make the wheel lighter"), [{"kind": "ffb", "value": 90}])
        self.assertEqual(self.act("the brakes are too strong"), [{"kind": "brake", "value": 95}])
        self.assertEqual(self.act("more brake power"), [{"kind": "brake", "value": 105}])

    def test_undo(self):
        a = adj(ffbPct=90)
        for q in ("undo that", "put it back", "put the bias back", "back to stock", "reset the changes"):
            self.assertEqual(self.act(q, a), [{"kind": "revert"}], q)
        self.assertEqual(E.offline_adjust("undo", STOCK), ("Nothing to undo, it's all stock.", []))

    def test_questions_and_other_talk_change_nothing(self):
        for q in ("what's my brake bias", "how are my brakes", "is the ffb lighter now", "how much fuel",
                  "my brakes feel weak", "status report", "brake temperatures"):
            self.assertIsNone(E.offline_adjust(q, STOCK), q)

    def test_at_the_limit(self):
        text, actions = E.offline_adjust("more front bias", adj(biasShift=10))
        self.assertEqual(actions, [])
        self.assertIn("limit", text)

    def test_setup_question_offline(self):
        d = {"car": {}, "adjust": adj(biasShift=2, ffbPct=90, waiting=True)}
        text = E.offline_drive("what's my brake bias", d)
        self.assertIn("62 percent front", text)
        self.assertIn("force feedback at 90", text)


class ToolLoop(unittest.TestCase):
    def setUp(self):
        self.real = E.haiku_call

    def tearDown(self):
        E.haiku_call = self.real

    def run_tools(self, *responses, a=STOCK, q=None):
        E.haiku_call = api = FakeAPI(*responses)
        text, actions = E.drive_with_tools("sys", [{"role": "user", "content": "q"}], a, q)
        return text, actions, api

    def test_radio_line_comes_after_the_tool_result(self):
        # the text next to the call is often a preamble ("Sport is in the list, so I'll switch to it.")
        text, actions, api = self.run_tools(reply("Sport is in the list, so I'll switch.", tool_use("set_ffb_strength", {"percent": 90})),
                                            reply("Copy, wheel down to 90 percent.", stop="end_turn"))
        self.assertEqual((text, actions), ("Copy, wheel down to 90 percent.", [{"kind": "ffb", "value": 90}]))
        self.assertEqual(len(api.calls), 2)
        self.assertEqual([t["name"] for t in api.calls[0]["tools"]],
                         ["set_brake_bias", "set_brake_strength", "set_ffb_strength", "set_drive_mode", "set_driver_aids",
                          "set_launch_control", "set_awd_lock", "revert_adjustments"])

    def test_tool_only_asks_for_the_radio_line(self):
        text, actions, api = self.run_tools(reply(tool_use("set_brake_bias", {"front_shift": 2}, "tu_9")),
                                            reply("Two points forward, 62 percent front.", stop="end_turn"))
        self.assertEqual((text, actions), ("Two points forward, 62 percent front.", [{"kind": "bias", "value": 2}]))
        second = api.calls[1]
        self.assertEqual(second["tool_choice"], {"type": "none"})
        result = second["messages"][-1]["content"][0]
        self.assertEqual((result["type"], result["tool_use_id"]), ("tool_result", "tu_9"))
        self.assertEqual(second["messages"][-2]["role"], "assistant")

    def test_limited_value_is_reported_back(self):
        text, actions, api = self.run_tools(reply("Copy, brakes to 150.", tool_use("set_brake_strength", {"percent": 150})),
                                            reply("Maxed out at 110 percent.", stop="end_turn"))
        self.assertEqual(actions, [{"kind": "brake", "value": 110}])
        self.assertEqual(text, "Maxed out at 110 percent.")
        self.assertIn("limited", api.calls[1]["messages"][-1]["content"][0]["content"])

    def test_two_tools_one_reply(self):
        _, actions, api = self.run_tools(reply("Copy.", tool_use("set_brake_bias", {"front_shift": 2}, "a"),
                                               tool_use("set_ffb_strength", {"percent": 90}, "b")), reply("Both done.", stop="end_turn"))
        self.assertEqual(actions, [{"kind": "bias", "value": 2}, {"kind": "ffb", "value": 90}])
        self.assertEqual([r["tool_use_id"] for r in api.calls[1]["messages"][-1]["content"]], ["a", "b"])  # one message, both results

    def test_a_claimed_change_without_a_tool_call_is_asked_again(self):
        text, actions, api = self.run_tools(reply("Copy, launch control set to 4500 rpm.", stop="end_turn"),
                                            reply(tool_use("set_launch_control", {"rpm": 4500})),
                                            reply("Launch at 4500, copy.", stop="end_turn"), a=VIVACE, q="Set the launch rpm to 4500.")
        self.assertEqual((text, actions), ("Launch at 4500, copy.", [{"kind": "launchRPM", "value": 4500}]))
        self.assertIn("didn't call a tool", api.calls[1]["messages"][-1]["content"])

    def test_still_no_tool_call_uses_the_phrases(self):
        text, actions, api = self.run_tools(reply("Copy, traction control off.", stop="end_turn"),
                                            reply("Done.", stop="end_turn"), a=VIVACE, q="traction control off")
        self.assertEqual(actions, [{"kind": "tc", "value": False}])
        self.assertIn("traction control off", text)

    def test_questions_are_not_asked_again(self):
        _, actions, api = self.run_tools(reply("Traction control is on.", stop="end_turn"), a=VIVACE, q="is traction control on")
        self.assertEqual((actions, len(api.calls)), ([], 1))

    def test_no_tool(self):
        self.assertEqual(self.run_tools(reply("Brakes at 300, all good.", stop="end_turn"))[:2], ("Brakes at 300, all good.", []))

    def test_follow_up_failure_falls_back_to_a_canned_line(self):
        text, actions, _ = self.run_tools(reply(tool_use("set_ffb_strength", {"percent": 90})), urllib.error.URLError("offline"))
        self.assertEqual(text, "Copy, force feedback at 90 percent.")
        self.assertEqual(actions, [{"kind": "ffb", "value": 90}])


class AnswerAndBridge(unittest.TestCase):
    def setUp(self):
        self.real = (E.haiku_call, E.API_KEY, E.DIR)
        E.radio["turns"], E.radio["t"] = [], 0

    def tearDown(self):
        E.haiku_call, E.API_KEY, E.DIR = self.real

    def ask(self, q, mode="drive", a=STOCK):
        return E.answer({"type": "ask", "question": q, "mode": mode, "data": {"car": {}, "adjust": a}})

    def test_without_key(self):
        E.API_KEY = ""
        self.assertEqual(self.ask("more front bias")[2], [{"kind": "bias", "value": 2}])
        self.assertEqual(self.ask("how are my brakes")[2], [])
        self.assertEqual(E.answer({"question": "more front bias", "mode": "review", "data": {}})[2], [])

    def test_with_haiku(self):
        E.API_KEY = "test"
        E.haiku_call = FakeAPI(reply(tool_use("set_ffb_strength", {"percent": 90})), reply("Copy, lighter wheel, 90 percent.", stop="end_turn"))
        text, source, actions = self.ask("ffb lighter please")
        self.assertEqual((source, actions), ("haiku", [{"kind": "ffb", "value": 90}]))
        self.assertIn('"adjust"', E.haiku_call.calls[0]["messages"][-1]["content"])
        self.assertTrue(all(isinstance(m["content"], str) for m in E.radio["turns"]))  # history stays plain text

    def test_haiku_down_uses_the_phrases(self):
        E.API_KEY = "test"
        E.haiku_call = FakeAPI(urllib.error.URLError("no network"))
        text, source, actions = self.ask("undo that", a=adj(brakePct=95))
        self.assertEqual((source, actions), ("offline (Haiku unavailable)", [{"kind": "revert"}]))

    def test_answer_file_carries_the_actions(self):
        E.API_KEY = ""

        class NoSpeech:
            ok = False

        with tempfile.TemporaryDirectory() as d:
            E.DIR = d
            E.handle(NoSpeech(), {"type": "ask", "id": "1_00001", "question": "more front bias", "mode": "drive",
                                  "data": {"car": {}, "adjust": STOCK}})
            with open(os.path.join(d, "res_1_00001.json"), encoding="utf-8") as f:
                res = json.load(f)
        self.assertEqual(res["actions"], [{"kind": "bias", "value": 2}])
        self.assertIn("forward", res["text"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
