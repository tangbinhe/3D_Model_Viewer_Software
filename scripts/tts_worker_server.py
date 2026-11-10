#!/usr/bin/env python
"""3D Model Viewer 专用 TTS worker，避免与终端版单连接 worker 相互阻塞。"""

import json
import os
import socket
from datetime import datetime
from pathlib import Path

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

import numpy as np
from mlx_audio.audio_io import write as audio_write
from mlx_audio.tts.utils import load_model

HOST = "127.0.0.1"
PORT = 8011
TTS_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
OUTPUT_DIR = Path.home() / "AI-Avatar" / "audio" / "live"


def synthesize(model, req):
    out_dir = OUTPUT_DIR / datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    out_dir.mkdir(parents=True, exist_ok=True)

    results = model.generate(
        text=req["text"],
        voice=req.get("voice", "Serena"),
        lang_code=req.get("lang_code", "Chinese"),
        speed=req.get("speed", 1.0),
        temperature=req.get("temperature", 0.7),
        verbose=False,
        stream=False,
    )

    first_path = None
    for i, result in enumerate(results):
        path = out_dir / f"audio_{i:03d}.wav"
        audio_write(str(path), np.array(result.audio), result.sample_rate, format="wav")
        if first_path is None:
            first_path = path

    if first_path is None:
        raise RuntimeError("TTS 未生成任何音频")
    return first_path


def main():
    print("正在加载 TTS 模型……", flush=True)
    model = load_model(model_path=TTS_MODEL)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(4)
    print("READY", flush=True)

    while True:
        conn, _ = server.accept()
        with conn, conn.makefile("r", encoding="utf-8") as infile:
            for line in infile:
                line = line.strip()
                if not line:
                    continue
                try:
                    resp = {"wav": str(synthesize(model, json.loads(line)))}
                except Exception as e:
                    resp = {"error": f"{type(e).__name__}: {e}"}
                conn.sendall(
                    (json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8")
                )


if __name__ == "__main__":
    main()
