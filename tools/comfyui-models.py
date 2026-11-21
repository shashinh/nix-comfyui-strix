#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
"""Check or fetch the models a ComfyUI setup declares.

The manifest is a JSON list of entries:
  {"path": "vae/x.safetensors", "url": "...", "sha256": "<hex>",
   "size": 123, "license": "Apache-2.0", "source": "..."}
`path` is relative to the models directory. Files in the models directory that
the manifest does not declare are ignored.

  comfyui-models check    exit 1 and list each missing/incomplete file
  comfyui-models fetch    print total size + destination, then download
                          (resumable, sha256-verified)
  comfyui-models verify   sha256 every present declared file (slow)
  comfyui-models list     show the manifest with sizes and licenses

Models dir: --models-dir, else $COMFYUI_MODELS_DIR, else /data/models/comfyui.
Manifest:   --manifest,   else $COMFYUI_MODELS_MANIFEST.
"""

import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

DEFAULT_MODELS_DIR = "/data/models/comfyui"


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1000
    return f"{n:.1f} TB"


def load(args):
    manifest = args.manifest or os.environ.get("COMFYUI_MODELS_MANIFEST")
    if not manifest:
        sys.exit("comfyui-models: no manifest (--manifest or COMFYUI_MODELS_MANIFEST)")
    entries = json.loads(Path(manifest).read_text())
    models_dir = Path(args.models_dir or os.environ.get("COMFYUI_MODELS_DIR") or DEFAULT_MODELS_DIR)
    return manifest, entries, models_dir


def status(entry, models_dir: Path) -> str:
    p = models_dir / entry["path"]
    if not p.exists():
        return "missing"
    if entry.get("size") is not None and p.stat().st_size != entry["size"]:
        return "wrong size"
    return "ok"


def fetch_cmd(args, models_dir: Path, manifest: str) -> str:
    cmd = ["comfyui-models", "fetch", "--models-dir", str(models_dir)]
    if args.manifest:
        cmd += ["--manifest", manifest]
    return shlex.join(cmd)


def cmd_check(args) -> int:
    manifest, entries, models_dir = load(args)
    bad = [(e, status(e, models_dir)) for e in entries]
    bad = [(e, s) for e, s in bad if s != "ok"]
    if not bad:
        print(f"comfyui-models: all {len(entries)} declared models present in {models_dir}")
        return 0
    total = sum(e.get("size") or 0 for e, _ in bad)
    print(f"comfyui-models: {len(bad)} of {len(entries)} declared models are not usable in {models_dir}:",
          file=sys.stderr)
    for e, s in bad:
        print(f"  [{s}] {e['path']}  ({human(e.get('size') or 0)}, {e.get('license', '?')})", file=sys.stderr)
    print(f"Fetch them ({human(total)}) with:\n  {fetch_cmd(args, models_dir, manifest)}", file=sys.stderr)
    print("or remove them from the declared model list.", file=sys.stderr)
    return 1


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(16 * 1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def cmd_fetch(args) -> int:
    _, entries, models_dir = load(args)
    todo = [e for e in entries if status(e, models_dir) != "ok"]
    if not todo:
        print(f"comfyui-models: nothing to fetch, all declared models present in {models_dir}")
        return 0
    total = sum(e.get("size") or 0 for e in todo)
    print(f"Destination: {models_dir}")
    for e in todo:
        print(f"  {e['path']}  {human(e.get('size') or 0)}  [{e.get('license', '?')}]  {e.get('source', '')}")
    print(f"Total: {human(total)} in {len(todo)} file(s)")
    if not args.yes:
        if not sys.stdin.isatty():
            print("Not a terminal: re-run with --yes to download.", file=sys.stderr)
            return 1
        if input("Download? [y/N] ").strip().lower() not in ("y", "yes"):
            return 1
    for e in todo:
        dest = models_dir / e["path"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + ".part")
        if dest.exists():  # wrong size: restart from a partial file
            dest.rename(part)
        print(f"==> {e['path']}", flush=True)
        subprocess.run(
            ["curl", "--fail", "--location", "--retry", "5", "--retry-delay", "5",
             "--continue-at", "-", "--output", str(part), e["url"]],
            check=True,
        )
        if e.get("size") is not None and part.stat().st_size != e["size"]:
            print(f"size mismatch for {e['path']}: got {part.stat().st_size}, want {e['size']}", file=sys.stderr)
            return 1
        if e.get("sha256"):
            print("    verifying sha256 ...", flush=True)
            got = sha256_of(part)
            if got != e["sha256"]:
                print(f"sha256 mismatch for {e['path']}: got {got}, want {e['sha256']}; "
                      f"left as {part}", file=sys.stderr)
                return 1
        part.rename(dest)
        print(f"    ok -> {dest}")
    return 0


def cmd_verify(args) -> int:
    _, entries, models_dir = load(args)
    rc = 0
    for e in entries:
        p = models_dir / e["path"]
        if not p.exists():
            print(f"[missing ] {e['path']}")
            rc = 1
            continue
        got = sha256_of(p)
        ok = got == e.get("sha256", got)
        print(f"[{'ok' if ok else 'MISMATCH':8}] {e['path']}")
        rc |= 0 if ok else 1
    return rc


def cmd_list(args) -> int:
    manifest, entries, models_dir = load(args)
    print(f"manifest: {manifest}\nmodels dir: {models_dir}")
    for e in entries:
        print(f"  [{status(e, models_dir):10}] {e['path']}  {human(e.get('size') or 0)}  "
              f"{e.get('license', '?')}  {e.get('source', '')}")
    print(f"total declared: {human(sum(e.get('size') or 0 for e in entries))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="comfyui-models", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-dir")
    ap.add_argument("--manifest")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    f = sub.add_parser("fetch")
    f.add_argument("--yes", "-y", action="store_true", help="do not ask before downloading")
    sub.add_parser("verify")
    sub.add_parser("list")
    # allow global options after the subcommand too
    for name in ("check", "fetch", "verify", "list"):
        sp = sub.choices[name]
        sp.add_argument("--models-dir", dest="models_dir_sub")
        sp.add_argument("--manifest", dest="manifest_sub")
    args = ap.parse_args()
    args.models_dir = getattr(args, "models_dir_sub", None) or args.models_dir
    args.manifest = getattr(args, "manifest_sub", None) or args.manifest
    return {"check": cmd_check, "fetch": cmd_fetch, "verify": cmd_verify, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
