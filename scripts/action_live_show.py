#!/usr/bin/env python

import json
import os
import queue
import sys
import threading
import time
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.home() / "AI-Avatar"))
os.environ["HF_HUB_OFFLINE"] = "1"
for proxy_name in (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
):
    os.environ.pop(proxy_name, None)

import tts_chat_lipsync

tts_chat_lipsync.WORKER_PORT = 8011
tts_chat_lipsync.WORKER_SCRIPT = SCRIPT_DIR / "tts_worker_server.py"
tts_chat_lipsync.WORKER_LOG = (
    tts_chat_lipsync.BASE_DIR / "logs" / "model_viewer_tts_worker.log"
)

import live_show


PLAYER_EVENTS = queue.Queue(maxsize=100)
PLAYER_EVENT_SEEN = {}


def player_event_worker():
    while True:
        text = PLAYER_EVENTS.get()
        request = urllib.request.Request(
            "http://127.0.0.1:8765/api/command",
            data=json.dumps({"danmaku": text, "danmakuVisible": True}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=0.75):
                pass
        except OSError:
            pass


def forward_player_events(pending):
    now = time.monotonic()
    for key, timestamp in list(PLAYER_EVENT_SEEN.items()):
        if now - timestamp > 60:
            del PLAYER_EVENT_SEEN[key]
    for event in pending:
        if not isinstance(event, dict) or event.get("kind") != "chat":
            continue
        text = str(event.get("content") or "").strip()
        if not text:
            continue
        key = (str(event.get("user") or ""), text)
        if not event.get("owner"):
            if key in PLAYER_EVENT_SEEN:
                continue
            PLAYER_EVENT_SEEN[key] = now
        try:
            PLAYER_EVENTS.put_nowait(text)
        except queue.Full:
            break


threading.Thread(target=player_event_worker, daemon=True).start()
original_pick_and_reply = live_show.pick_and_reply


def pick_and_reply_with_player_events(pending, persona, history, seen, last_follow_reply):
    forward_player_events(pending)
    return original_pick_and_reply(pending, persona, history, seen, last_follow_reply)


live_show.pick_and_reply = pick_and_reply_with_player_events


if __name__ == "__main__":
    live_show.main()
