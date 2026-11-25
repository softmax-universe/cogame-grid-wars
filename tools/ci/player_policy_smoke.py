#!/usr/bin/env python3
"""Exercise Grid Wars game, prompt, canned, and scripted players on one native build."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GAME, PLAYER = sys.argv[1:3]
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
PAINTER = (ROOT / "data/warriors/painter.gwl").read_text().splitlines()
requests = {"prompt": 0}


def check_ordinary_parser():
    spec = importlib.util.spec_from_file_location("ordinary_player", ROOT / "players/ordinary/player.py")
    assert spec and spec.loader
    sys.path.insert(0, str(ROOT / "players/ordinary"))
    try:
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.path.pop(0)
    payload = {"script": ["while true:", "  place()"], "notes": "", "banner": ""}
    encoded = json.dumps(payload)
    assert mod.parse_json_object(encoded) == payload
    assert mod.parse_json_object(f"```json\n{encoded}\n```") == payload
    assert mod.parse_json_object(f"```\n{encoded}\n```") == payload
    for bad in (
        f"Here you go:\n{encoded}",
        f"{encoded}\nHope this helps!",
        f"{encoded}\n{encoded}",
        f"```json\n{encoded}\n```\nExtra prose",
        f"```python\n{encoded}\n```",
        "[]",
    ):
        try:
            mod.parse_json_object(bad)
            raise AssertionError(f"should have rejected: {bad!r}")
        except ValueError:
            pass


check_ordinary_parser()


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/v1/messages"
        assert body["model"] == "anthropic/claude-haiku-4.5"
        assert "anthropic_version" not in body
        assert "Maximize your mean roundScore across the rounds played." in body["system"]
        assert "50 per self-kill" in body["system"]
        requests["prompt"] += 1
        slot = self.headers["X-Coworld-Player-Slot"]
        if slot == "1":
            # Round 1 bare JSON, round 2 wrapped in a single outer ```json fence.
            raw = json.dumps({"script": PAINTER, "notes": "stub", "banner": "painting"})
            text = raw if requests["prompt"] == 1 else f"```json\n{raw}\n```"
        else:
            # Slot 3 returns surrounding prose, which must be rejected and forfeited (no sentry substitution).
            text = json.dumps({"script": PAINTER}) + "\nGood luck!"
        response = {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}
        encoded = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        pass


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
threading.Thread(target=model.serve_forever, daemon=True).start()
port = free_port()
with tempfile.TemporaryDirectory(prefix="gridwars-policy-") as scratch:
    root = Path(scratch)
    config = {"tokens": [f"token-{seat}" for seat in range(4)],
              "players": [{"name": f"Policy {seat}"} for seat in range(4)],
              "seed": 7, "promptVariant": "mixed", "promptSeed": 4, "rounds": 2, "ticks": 30, "sampled": True,
              "roundDelayMs": 0, "actionTimeoutSeconds": 8,
              "player_connect_timeout_seconds": 8}
    (root / "config.json").write_text(json.dumps(config))
    game_env = os.environ.copy()
    game_env.update({"COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                     "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
                     "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
                     "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri()})
    game = subprocess.Popen([GAME], env=game_env,
                            stdout=(root / "game.log").open("w"), stderr=subprocess.STDOUT)
    players = []
    try:
        for _ in range(100):
            if game.poll() is not None:
                raise AssertionError((root / "game.log").read_text())
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise AssertionError("game socket unavailable")
        for slot, settings in enumerate((
            {"POC_CAPTURE_TRAINING": "1", "POC_SOURCE_REVISION": "fixture",
             "COWORLD_PLAYER_ARTIFACT_UPLOAD_URL": (root / "ordinary.zip").as_uri()},
            {"PLAYER_PROMPT": "Paint and survive."},
            {"PLAYER_SCRIPTED": "painter"},
            {"PLAYER_SCRIPTED": "bomber"},
        )):
            env = os.environ.copy()
            env.update(settings)
            env.update({"COWORLD_PLAYER_WS_URL":
                        f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}",
                        "COWORLD_LLM_ENDPOINT":
                        f"http://127.0.0.1:{model.server_port}"})
            command = [sys.executable, str(ROOT / "players/ordinary/player.py")] if slot == 0 else [PLAYER]
            players.append(subprocess.Popen(command, env=env, cwd=ROOT,
                           stdout=(root / f"player-{slot}.log").open("w"),
                           stderr=subprocess.STDOUT))
        assert game.wait(timeout=65) == 0, (root / "game.log").read_text()
        for slot, player in enumerate(players):
            assert player.wait(timeout=5) == 0, (root / f"player-{slot}.log").read_text()
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert requests == {"prompt": 2}, requests
        assert results["reason"] == "complete", results
        submissions = [event for event in replay["events"] if event["kind"] == "submit"]
        assert len(submissions) == 8, len(submissions)
        assert [event["origin"] for event in submissions] == [
            "player", "player", "scripted", "scripted"] * 2, submissions
        with zipfile.ZipFile(root / "ordinary.zip") as archive:
            trajectory = json.loads(archive.read("trajectory.json"))
        assert len(trajectory["decisions"]) == 2
        for decision in trajectory["decisions"]:
            assert decision["prompt_template"]["variant"] == "reordered"
            assert "Maximize your mean roundScore across the rounds played." in decision["prompt"][0]["content"]
        print("Grid Wars player smoke: 2 canned, 2 prompt (bare + fenced), 4 scripted programs, zero fallback")
        # Second episode: verify rejected prompt reply and missing-credential prompt player forfeit with empty script.
        scratch2 = root / "forfeit"
        scratch2.mkdir()
        (scratch2 / "config.json").write_text(json.dumps(config))
        port2 = free_port()
        game2_env = os.environ.copy()
        game2_env.update({"COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port2),
                          "COGAME_CONFIG_URI": (scratch2 / "config.json").as_uri(),
                          "COGAME_RESULTS_URI": (scratch2 / "results.json").as_uri(),
                          "COGAME_SAVE_REPLAY_URI": (scratch2 / "replay.json").as_uri()})
        game2 = subprocess.Popen([GAME], env=game2_env,
                                 stdout=(scratch2 / "game.log").open("w"), stderr=subprocess.STDOUT)
        players2 = []
        try:
            for _ in range(100):
                if game2.poll() is not None:
                    raise AssertionError((scratch2 / "game.log").read_text())
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port2)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game2 socket unavailable")
            for slot, settings, with_endpoint in (
                (0, {"PLAYER_SCRIPTED": "painter"}, False),
                (1, {"PLAYER_SCRIPTED": "bomber"}, False),
                (2, {"PLAYER_PROMPT": "No credentials."}, False),
                (3, {"PLAYER_PROMPT": "Trailing prose reply."}, True),
            ):
                env = {k: v for k, v in os.environ.items()
                       if k not in ("COWORLD_LLM_ENDPOINT", "ANTHROPIC_API_KEY",
                                    "ANTHROPIC_API_KEY_URI", "AWS_BEARER_TOKEN_BEDROCK",
                                    "AWS_ENDPOINT_URL_BEDROCK_RUNTIME")}
                env.update(settings)
                env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port2}/player?slot={slot}&token=token-{slot}"
                if with_endpoint:
                    env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{model.server_port}"
                players2.append(subprocess.Popen([PLAYER], env=env, cwd=ROOT,
                                stdout=(scratch2 / f"player-{slot}.log").open("w"),
                                stderr=subprocess.STDOUT))
            assert game2.wait(timeout=65) == 0, (scratch2 / "game.log").read_text()
            for slot, player in enumerate(players2):
                assert player.wait(timeout=5) == 0, (scratch2 / f"player-{slot}.log").read_text()
            results2 = json.loads((scratch2 / "results.json").read_text())
            replay2 = json.loads((scratch2 / "replay.json").read_text())
            assert results2["reason"] == "complete", results2
            assert results2["fallbacks"] == [0, 0, 2, 2], results2
            subs2 = [event for event in replay2["events"] if event["kind"] == "submit"]
            assert [event["origin"] for event in subs2] == [
                "scripted", "scripted", "forfeit", "forfeit"] * 2, subs2
            for event in subs2:
                if event["seat"] in (2, 3):
                    assert event["script"] == [], event
                    assert event["compileError"], event
            print("Grid Wars forfeit smoke: rejected prose and missing credentials forfeit with empty script")
        finally:
            for process in [*players2, game2]:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
    finally:
        for process in [*players, game]:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        model.shutdown()
