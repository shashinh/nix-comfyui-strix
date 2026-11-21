#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
"""Submit an API-format ComfyUI workflow, wait for it, save the outputs.

  run-workflow workflows/klein-t2i.json --prompt "a red fox" --seed 7
  run-workflow workflows/klein-edit.json --image in.png --prompt "make it night"
  run-workflow wf.json --url http://127.0.0.1:8686/comfyui --set 8.steps=8

Overrides:
  --prompt  sets `text` on nodes titled "prompt" (case-insensitive); if none,
            on the first CLIPTextEncode
  --seed    sets every `seed` / `noise_seed` input
  --image   uploads the file and sets `image` on every LoadImage node
  --set N.INPUT=VALUE   any input (VALUE parsed as JSON, else string)

Prints total wall time (submit -> done) and seconds per sampling step,
measured from the server's progress events between the first and last step.
Stdlib only (includes a minimal WebSocket client).
"""

import argparse
import base64
import json
import mimetypes
import os
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


# ---------------------------------------------------------------- websocket
class WS:
    def __init__(self, url: str, timeout: float):
        u = urllib.parse.urlsplit(url)
        port = u.port or (443 if u.scheme == "wss" else 80)
        raw = socket.create_connection((u.hostname, port), timeout=timeout)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=u.hostname) \
            if u.scheme == "wss" else raw
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + ("?" + u.query if u.query else "")
        req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket closed during handshake")
            head += chunk
        status_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in status_line + " ":
            raise ConnectionError(f"websocket handshake failed: {status_line}")
        self.buf = head.split(b"\r\n\r\n", 1)[1]

    def _read(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        """Return (opcode, payload) of the next complete message."""
        msg, op0 = b"", None
        while True:
            b1, b2 = self._read(2)
            fin, op, ln = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(ln)
            if mask:
                data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
            if op == 0x9:  # ping -> pong
                self._send(0xA, data)
                continue
            if op == 0x8:
                raise ConnectionError("websocket closed by server")
            if op0 is None:
                op0 = op
            msg += data
            if fin:
                return op0, msg

    def _send(self, op: int, data: bytes):
        mask = os.urandom(4)
        hdr = bytes([0x80 | op])
        n = len(data)
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(hdr + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def settimeout(self, t):
        self.sock.settimeout(t)


# ---------------------------------------------------------------- http
def http(method: str, url: str, body=None, headers=None, timeout=600):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def upload(base: str, path: Path) -> str:
    boundary = uuid.uuid4().hex
    ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{path.name}\"\r\n"
            f"Content-Type: {ctype}\r\n\r\n").encode() + path.read_bytes() + \
           (f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue"
            f"\r\n--{boundary}--\r\n").encode()
    res = json.loads(http("POST", f"{base}/upload/image", body,
                          {"Content-Type": f"multipart/form-data; boundary={boundary}"}))
    return (res.get("subfolder") + "/" if res.get("subfolder") else "") + res["name"]


def parse_value(v: str):
    try:
        return json.loads(v)
    except json.JSONDecodeError:
        return v


def apply_overrides(wf: dict, args, image_name):
    if args.prompt is not None:
        titled = [n for n in wf.values() if n.get("_meta", {}).get("title", "").lower() == "prompt"]
        targets = titled or [next((n for n in wf.values() if n["class_type"] == "CLIPTextEncode"), None)]
        if not targets or targets[0] is None:
            sys.exit("--prompt: no node titled 'prompt' and no CLIPTextEncode")
        for n in targets:
            n["inputs"]["text"] = args.prompt
    if args.seed is not None:
        hit = False
        for n in wf.values():
            for k in ("seed", "noise_seed"):
                if k in n["inputs"] and not isinstance(n["inputs"][k], list):
                    n["inputs"][k] = args.seed
                    hit = True
        if not hit:
            sys.exit("--seed: no seed/noise_seed input in workflow")
    if image_name is not None:
        loads = [n for n in wf.values() if n["class_type"] == "LoadImage"]
        if not loads:
            sys.exit("--image: no LoadImage node in workflow")
        for n in loads:
            n["inputs"]["image"] = image_name
    for s in args.set:
        lhs, val = s.split("=", 1)
        node, inp = lhs.split(".", 1)
        if node not in wf:
            sys.exit(f"--set: no node {node}")
        wf[node]["inputs"][inp] = parse_value(val)


def main() -> int:
    ap = argparse.ArgumentParser(prog="run-workflow", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workflow", type=Path, help="API-format workflow JSON")
    ap.add_argument("--url", default=os.environ.get("COMFYUI_URL", "http://127.0.0.1:8188"),
                    help="ComfyUI base URL, e.g. http://127.0.0.1:8686/comfyui (default $COMFYUI_URL or :8188)")
    ap.add_argument("--prompt")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--image", type=Path)
    ap.add_argument("--set", action="append", default=[], metavar="NODE.INPUT=VALUE")
    ap.add_argument("--out", type=Path, default=Path("outputs"), help="directory for output images")
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--json", action="store_true", help="print a JSON summary as the last line")
    args = ap.parse_args()

    base = args.url.rstrip("/")
    wf = json.loads(args.workflow.read_text())
    if "nodes" in wf and "links" in wf:
        sys.exit("this is a UI-format workflow; export it with 'Export (API)'")

    t_submit = time.monotonic()
    image_name = upload(base, args.image) if args.image else None
    apply_overrides(wf, args, image_name)

    client_id = uuid.uuid4().hex
    try:
        res = json.loads(http("POST", f"{base}/prompt",
                              json.dumps({"prompt": wf, "client_id": client_id}).encode(),
                              {"Content-Type": "application/json"}, timeout=args.timeout))
    except urllib.error.HTTPError as e:
        sys.exit(f"submit failed: HTTP {e.code}: {e.read().decode(errors='replace')[:2000]}")
    if res.get("node_errors"):
        sys.exit(f"node errors: {json.dumps(res['node_errors'], indent=1)}")
    pid = res["prompt_id"]
    print(f"queued {pid}", file=sys.stderr)

    ws_url = base.replace("http://", "ws://").replace("https://", "wss://") + f"/ws?clientId={client_id}"
    ws = None
    for _ in range(60):
        try:
            ws = WS(ws_url, timeout=30)
            break
        except (ConnectionError, OSError):
            time.sleep(1)

    steps = []          # (monotonic time, value, max, node)
    node_times = {}     # node -> start time
    errors = None
    deadline = t_submit + args.timeout
    done = False
    if ws:
        ws.settimeout(5)
        while not done and time.monotonic() < deadline:
            try:
                op, data = ws.recv()
            except (TimeoutError, socket.timeout):
                # fall back to history polling in case we missed the end message
                hist = json.loads(http("GET", f"{base}/history/{pid}"))
                if pid in hist and hist[pid].get("status", {}).get("completed") is not None:
                    done = True
                continue
            if op != 0x1:
                continue
            m = json.loads(data)
            d = m.get("data", {})
            if d.get("prompt_id") not in (None, pid):
                continue
            t = m.get("type")
            if t == "progress":
                steps.append((time.monotonic(), d["value"], d["max"], d.get("node")))
            elif t == "executing" and d.get("node") is not None:
                node_times.setdefault(d["node"], time.monotonic())
            elif t in ("execution_success",) or (t == "executing" and d.get("node") is None):
                done = True
            elif t == "execution_error":
                errors = d
                done = True
            elif t == "execution_interrupted":
                errors = {"interrupted": d}
                done = True
    while not done and time.monotonic() < deadline:
        hist = json.loads(http("GET", f"{base}/history/{pid}"))
        if pid in hist and hist[pid].get("status", {}).get("completed") is not None:
            done = True
        else:
            time.sleep(0.5)
    t_done = time.monotonic()
    if not done:
        sys.exit(f"timed out after {args.timeout}s")

    hist = json.loads(http("GET", f"{base}/history/{pid}"))[pid]
    st = hist.get("status", {})
    if errors or st.get("status_str") == "error":
        msgs = [m for m in st.get("messages", []) if m[0] == "execution_error"]
        sys.exit(f"execution failed: {json.dumps(errors or msgs, indent=1)[:4000]}")

    args.out.mkdir(parents=True, exist_ok=True)
    saved = []
    for node, out in hist.get("outputs", {}).items():
        for img in out.get("images", []):
            if img.get("type") != "output":
                continue
            q = urllib.parse.urlencode({"filename": img["filename"], "subfolder": img.get("subfolder", ""),
                                        "type": img["type"]})
            dest = args.out / img["filename"]
            dest.write_bytes(http("GET", f"{base}/view?{q}"))
            saved.append(str(dest))

    total = t_done - t_submit
    # Sampling speed: the longest run of progress events from one node.
    s_per_step = None
    n_steps = None
    if steps:
        by_node = {}
        for ev in steps:
            by_node.setdefault(ev[3], []).append(ev)
        evs = max(by_node.values(), key=len)
        n_steps = evs[-1][2]
        if len(evs) >= 2:
            s_per_step = (evs[-1][0] - evs[0][0]) / (evs[-1][1] - evs[0][1])
    summary = {"prompt_id": pid, "total_s": round(total, 2), "steps": n_steps,
               "s_per_step": round(s_per_step, 3) if s_per_step else None, "outputs": saved}
    for p in saved:
        print(f"saved {p}")
    print(f"total {total:.2f} s" + (f", {s_per_step:.3f} s/step over {n_steps} steps" if s_per_step else
                                     " (no step timing: fewer than 2 progress events seen)"))
    if args.json:
        print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
