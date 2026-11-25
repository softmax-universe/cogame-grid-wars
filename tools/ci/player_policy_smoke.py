#!/usr/bin/env python3
"""Exercise Grid Wars game, prompt, canned, and scripted players on one native build."""

import importlib.util
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

ROOT = Path(__file__).resolve().parents[2]
PAINTER = (ROOT / "data/warriors/painter.gwl").read_text().splitlines()
requests = {"prompt": 0}
stub_mode = {"slot3": "ok"}


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
        elif stub_mode["slot3"] == "provider_error":
            encoded = json.dumps({"error": {"message": "upstream overloaded"}}).encode()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        elif stub_mode["slot3"] == "ambiguous":
            # Trailing prose / multiple objects must be rejected as model_action failure.
            text = json.dumps({"script": PAINTER}) + "\n" + json.dumps({"script": PAINTER})
        else:
            text = json.dumps({"script": PAINTER})
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


def wait_for_port(port, game, log_path):
    for _ in range(100):
        if game.poll() is not None:
            raise AssertionError(log_path.read_text())
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.05)
    raise AssertionError(f"game socket unavailable on {port}")


def clean_llm_env():
    return {
        k: v
        for k, v in os.environ.items()
        if k
        not in (
            "COWORLD_LLM_ENDPOINT",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        )
    }


def run_aborted_episode(scratch: Path, config: dict, player_specs: list[tuple[int, dict, bool]]):
    scratch.mkdir()
    (scratch / "config.json").write_text(json.dumps(config))
    port = free_port()
    game_env = os.environ.copy()
    game_env.update(
        {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (scratch / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (scratch / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (scratch / "replay.json").as_uri(),
            "COGAME_PLAYER_FAILURE_URI": (scratch / "player_failure.json").as_uri(),
        }
    )
    game = subprocess.Popen(
        [GAME], env=game_env, stdout=(scratch / "game.log").open("w"), stderr=subprocess.STDOUT
    )
    players = []
    try:
        wait_for_port(port, game, scratch / "game.log")
        for slot, settings, with_endpoint in player_specs:
            env = clean_llm_env()
            env.update(settings)
            env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}"
            if with_endpoint:
                env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{model.server_port}"
            players.append(
                subprocess.Popen(
                    [PLAYER],
                    env=env,
                    cwd=ROOT,
                    stdout=(scratch / f"player-{slot}.log").open("w"),
                    stderr=subprocess.STDOUT,
                )
            )
        game_rc = game.wait(timeout=30)
        player_rcs = [p.wait(timeout=10) for p in players]
        assert game_rc != 0, f"expected non-zero game exit on aborted episode, got 0\n{(scratch / 'game.log').read_text()}"
        assert not (scratch / "results.json").exists(), "aborted episode must not write numeric results.json"
        failure_path = scratch / "player_failure.json"
        assert failure_path.exists(), f"missing player_failure.json\n{(scratch / 'game.log').read_text()}"
        failure = json.loads(failure_path.read_text())
        assert set(failure.keys()) == {"failed_policy_index", "kind", "message"}, failure
        assert isinstance(failure["failed_policy_index"], int) and not isinstance(failure["failed_policy_index"], bool), failure
        assert failure["failed_policy_index"] >= 0, failure
        assert failure["kind"] in ("player_error", "episode_inconclusive"), failure
        assert isinstance(failure["message"], str) and 1 <= len(failure["message"]) <= 2000, failure
        replay = json.loads((scratch / "replay.json").read_text())
        assert "results" not in replay, f"aborted replay must not contain numeric results: {replay.keys()}"
        diagnostics = replay.get("failure")
        assert isinstance(diagnostics, dict) and diagnostics.get("failed") is True, replay
        assert diagnostics.get("seat") == failure["failed_policy_index"], (diagnostics, failure)
        return failure, diagnostics, player_rcs
    finally:
        for process in [*players, game]:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
threading.Thread(target=model.serve_forever, daemon=True).start()
port = free_port()
with tempfile.TemporaryDirectory(prefix="gridwars-policy-") as scratch:
    root = Path(scratch)
    config = {
        "tokens": [f"token-{seat}" for seat in range(4)],
        "players": [{"name": f"Policy {seat}"} for seat in range(4)],
        "seed": 7,
        "promptVariant": "mixed",
        "promptSeed": 4,
        "rounds": 2,
        "ticks": 30,
        "sampled": True,
        "roundDelayMs": 0,
        "actionTimeoutSeconds": 8,
        "player_connect_timeout_seconds": 8,
    }
    (root / "config.json").write_text(json.dumps(config))
    game_env = os.environ.copy()
    game_env.update(
        {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri(),
            "COGAME_PLAYER_FAILURE_URI": (root / "player_failure.json").as_uri(),
        }
    )
    game = subprocess.Popen(
        [GAME], env=game_env, stdout=(root / "game.log").open("w"), stderr=subprocess.STDOUT
    )
    players = []
    try:
        wait_for_port(port, game, root / "game.log")
        for slot, settings in enumerate(
            (
                {
                    "POC_CAPTURE_TRAINING": "1",
                    "POC_SOURCE_REVISION": "fixture",
                    "COWORLD_PLAYER_ARTIFACT_UPLOAD_URL": (root / "ordinary.zip").as_uri(),
                },
                {"PLAYER_PROMPT": "Paint and survive."},
                {"PLAYER_SCRIPTED": "painter"},
                {"PLAYER_SCRIPTED": "bomber"},
            )
        ):
            env = clean_llm_env()
            env.update(settings)
            env.update(
                {
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}",
                    "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{model.server_port}",
                }
            )
            command = [sys.executable, str(ROOT / "players/ordinary/player.py")] if slot == 0 else [PLAYER]
            players.append(
                subprocess.Popen(
                    command,
                    env=env,
                    cwd=ROOT,
                    stdout=(root / f"player-{slot}.log").open("w"),
                    stderr=subprocess.STDOUT,
                )
            )
        assert game.wait(timeout=65) == 0, (root / "game.log").read_text()
        for slot, player in enumerate(players):
            assert player.wait(timeout=5) == 0, (root / f"player-{slot}.log").read_text()
        assert not (root / "player_failure.json").exists()
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert requests == {"prompt": 2}, requests
        assert results["reason"] == "complete", results
        assert results["fallbacks"] == [0, 0, 0, 0], results
        submissions = [event for event in replay["events"] if event["kind"] == "submit"]
        assert len(submissions) == 8, len(submissions)
        assert [event["origin"] for event in submissions] == [
            "player",
            "player",
            "scripted",
            "scripted",
        ] * 2, submissions
        with zipfile.ZipFile(root / "ordinary.zip") as archive:
            trajectory = json.loads(archive.read("trajectory.json"))
        assert len(trajectory["decisions"]) == 2
        seat0_subs = [event for event in submissions if event["seat"] == 0]
        for decision, sub in zip(trajectory["decisions"], seat0_subs):
            assert decision["prompt_template"]["variant"] == "reordered"
            assert "Maximize your mean roundScore across the rounds played." in decision["prompt"][0]["content"]
            captured = json.loads(decision["completion"][0]["content"])
            assert captured["script"] == sub["script"], (captured, sub)
            assert captured["notes"] == sub.get("text", ""), (captured, sub)
            assert captured["banner"] == sub.get("banner", ""), (captured, sub)
        print("Grid Wars player smoke: 2 canned, 2 prompt (bare + fenced), 4 scripted programs, zero fallback")

        # Episode 2: invalid/ambiguous model output (two JSON objects) -> player_error abort, no results.json
        stub_mode["slot3"] = "ambiguous"
        failure_invalid, diag_invalid, rcs_invalid = run_aborted_episode(
            root / "invalid_action",
            config,
            [
                (0, {"PLAYER_SCRIPTED": "painter"}, False),
                (1, {"PLAYER_SCRIPTED": "bomber"}, False),
                (2, {"PLAYER_SCRIPTED": "painter"}, False),
                (3, {"PLAYER_PROMPT": "Ambiguous reply."}, True),
            ],
        )
        assert failure_invalid["kind"] == "player_error", failure_invalid
        assert failure_invalid["failed_policy_index"] == 3, failure_invalid
        assert diag_invalid["failure_class"] == "model_action", diag_invalid
        assert diag_invalid["kind"] == "invalid_action", diag_invalid
        assert diag_invalid["seat"] == 3, diag_invalid
        assert rcs_invalid[3] != 0 and rcs_invalid[:3] == [0, 0, 0], rcs_invalid
        print("Grid Wars invalid-action smoke: ambiguous reply aborted unscored with player_error failure")

        # Episode 3: provider HTTP 503 failure -> episode_inconclusive abort, no results.json
        stub_mode["slot3"] = "provider_error"
        failure_provider, diag_provider, rcs_provider = run_aborted_episode(
            root / "provider_error",
            config,
            [
                (0, {"PLAYER_SCRIPTED": "painter"}, False),
                (1, {"PLAYER_SCRIPTED": "bomber"}, False),
                (2, {"PLAYER_SCRIPTED": "painter"}, False),
                (3, {"PLAYER_PROMPT": "Provider failure."}, True),
            ],
        )
        assert failure_provider["kind"] == "episode_inconclusive", failure_provider
        assert failure_provider["failed_policy_index"] == 3, failure_provider
        assert "503" in failure_provider["message"], failure_provider
        assert diag_provider["failure_class"] == "infrastructure", diag_provider
        assert diag_provider["kind"] == "provider_error", diag_provider
        assert diag_provider["seat"] == 3, diag_provider
        assert rcs_provider[3] != 0 and rcs_provider[:3] == [0, 0, 0], rcs_provider
        print("Grid Wars provider-error smoke: HTTP 503 aborted unscored with episode_inconclusive failure")

        # Episode 4: missing credentials -> episode_inconclusive abort, no results.json
        failure_creds, diag_creds, rcs_creds = run_aborted_episode(
            root / "missing_creds",
            config,
            [
                (0, {"PLAYER_SCRIPTED": "painter"}, False),
                (1, {"PLAYER_SCRIPTED": "bomber"}, False),
                (2, {"PLAYER_PROMPT": "No credentials."}, False),
                (3, {"PLAYER_SCRIPTED": "painter"}, False),
            ],
        )
        assert failure_creds["kind"] == "episode_inconclusive", failure_creds
        assert failure_creds["failed_policy_index"] == 2, failure_creds
        assert diag_creds["failure_class"] == "infrastructure", diag_creds
        assert diag_creds["kind"] == "missing_credentials", diag_creds
        assert diag_creds["seat"] == 2, diag_creds
        assert rcs_creds[2] != 0 and rcs_creds[0] == 0 and rcs_creds[1] == 0 and rcs_creds[3] == 0, rcs_creds
        print("Grid Wars missing-credentials smoke: aborted unscored with episode_inconclusive failure")
    finally:
        for process in [*players, game]:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        model.shutdown()
