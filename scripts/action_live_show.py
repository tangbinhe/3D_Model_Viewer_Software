#!/usr/bin/env python

import os
import sys
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


if __name__ == "__main__":
    live_show.main()
