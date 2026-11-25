"""Grid Wars programs through the game's ordinary player WebSocket."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture


def parse_json_object(text: str) -> dict:
    """Parse one JSON object, bare or inside one outer Markdown code fence."""
    cleaned = text.strip()
    if cleaned.startswith("\ufeff"):
        cleaned = cleaned[1:].strip()
    if cleaned.startswith("```"):
        first_break = cleaned.find("\n")
        if first_break < 0:
            raise ValueError("unterminated markdown fence in response")
        tag = cleaned[3:first_break].strip().lower()
        if tag not in ("", "json"):
            raise ValueError(f"unsupported markdown fence language tag: {tag}")
        body = cleaned[first_break + 1 :]
        if not body.endswith("```"):
            raise ValueError("trailing text after closing markdown fence")
        inner = body[:-3]
        before_close = inner.rstrip(" \t\r")
        if before_close and not before_close.endswith("\n"):
            raise ValueError("closing markdown fence must be on its own line")
        cleaned = inner.strip()
    if not cleaned:
        raise ValueError("empty JSON response")
    action = json.loads(cleaned)
    if not isinstance(action, dict):
        raise ValueError("trained Grid Wars submission must be a JSON object")
    return action


def choose(turn: dict, generator) -> tuple[dict, str]:
    turn["user"] = turn["observation"] + "\n" + os.environ.get("PLAYER_PROMPT", "")
    warrior_dir = Path(
        os.environ.get("GRIDWARS_WARRIOR_DIR", Path(__file__).resolve().parents[2] / "data" / "warriors")
    )
    if generator:
        completion = generator(
            [
                {"role": "system", "content": turn["system"]},
                {"role": "user", "content": turn["user"]},
            ]
        )
        return parse_json_object(completion), "trained"
    return {"script": (warrior_dir / "painter.gwl").read_text().splitlines(), "notes": "", "banner": ""}, "canned"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("POC_ADAPTER_DIR")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "canned"
    artifact = Capture(slot, backend) if os.environ.get("POC_CAPTURE_TRAINING") == "1" else None
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    pending: dict[int, tuple[dict, dict | None, str]] = {}
    local_error = False
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            if local_error:
                raise SystemExit(1)
            raise RuntimeError("Grid Wars closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            try:
                action, source = choose(frame, generator)
            except ValueError as exc:
                local_error = True
                pending[frame["round"]] = (frame, None, "error")
                socket.send(
                    json.dumps(
                        {
                            "type": "error",
                            "round": frame["round"],
                            "category": "model_action",
                            "kind": "invalid_action",
                            "reason": str(exc),
                        }
                    )
                )
            else:
                pending[frame["round"]] = (frame, action, source)
                socket.send(
                    json.dumps({"type": "submission", "round": frame["round"], "source": "player", "action": action})
                )
        elif kind == "submission_result":
            turn, action, source = pending.pop(frame["round"])
            executed_action = frame.get("action", action)
            if artifact and frame["accepted"] and executed_action is not None:
                artifact.record(
                    turn["system"],
                    turn["user"],
                    executed_action,
                    source,
                    frame["round"],
                    {
                        **turn["prompt_selection"],
                        "system_sha256": hashlib.sha256(turn["system"].encode()).hexdigest(),
                        "user_sha256": hashlib.sha256(turn["user"].encode()).hexdigest(),
                    },
                )
        elif kind == "final":
            if frame.get("failed"):
                break
            if pending:
                raise RuntimeError("Grid Wars ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"])
            break
    socket.close()
    if local_error:
        raise SystemExit(1)
    print(f"Grid Wars ordinary player finished: slot={slot} backend={backend}", flush=True)


if __name__ == "__main__":
    main()
