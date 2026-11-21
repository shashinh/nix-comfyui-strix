#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
"""Regenerate nix/torch-rocm/wheels.json from AMD's TheRock wheel index.

The index (https://stable.repo.amd.com/rocm/whl-next/) is a plain PEP 503
listing whose links carry no hashes, so every file is fetched once with
`nix-prefetch-url` (which also puts it in the store, so the following
`nix build` does not download it again) and its sha256 is recorded.

The file keeps the *requested* pins under "spec" and the resolved files under
"packages". Edit "spec" (or pass --set) and re-run:

    update-wheels                                  # re-resolve the current spec
    update-wheels --set torch=2.15.0+rocm10.2.0    # bump one pin
    update-wheels --python cp313                   # switch interpreter tag

Only stdlib + nix-prefetch-url are used.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_FILE = HERE / "wheels.json"


def index_links(index: str, project: str) -> list[str]:
    url = f"{index.rstrip('/')}/{project}/"
    with urllib.request.urlopen(url, timeout=60) as r:
        html = r.read().decode()
    return [urllib.parse.unquote(h) for h in re.findall(r'href="([^"]+)"', html)]


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "_", name).lower()


def pick(links: list[str], project: str, version: str, pytag: str) -> str:
    """Pick the linux_x86_64 wheel (or the sdist) for project==version."""
    stem = f"{norm(project)}-{version}"
    cands = []
    for f in links:
        f = f.split("#")[0].rsplit("/", 1)[-1]
        if f.endswith(".tar.gz"):
            if norm(f[: -len(".tar.gz")]) == norm(stem):
                cands.append((2, f))
            continue
        if not f.endswith(".whl"):
            continue
        parts = f[:-4].split("-")
        if len(parts) < 5:
            continue
        name, ver, py, abi, plat = parts[0], parts[1], parts[-3], parts[-2], parts[-1]
        if norm(name) != norm(project) or ver != version:
            continue
        if plat not in ("linux_x86_64", "any") and not plat.startswith("manylinux"):
            continue
        if py == pytag and abi == pytag:
            cands.append((0, f))
        elif py.startswith("py3") and abi in ("none", "abi3"):
            cands.append((1, f))
    if not cands:
        raise SystemExit(f"no file for {project}=={version} ({pytag}, linux_x86_64) in index")
    return sorted(cands)[0][1]


def prefetch(url: str, name: str) -> str:
    out = subprocess.run(
        ["nix-prefetch-url", "--type", "sha256", "--name", name, url],
        check=True, capture_output=True, text=True,
    ).stdout.strip().splitlines()[-1]
    sri = subprocess.run(
        ["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", out],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return sri


def store_name(filename: str) -> str:
    # store path names may not contain '+'; keep the rest readable
    return filename.replace("+", "_")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=Path, default=DEFAULT_FILE)
    ap.add_argument("--python", help="interpreter tag, e.g. cp314")
    ap.add_argument("--set", action="append", default=[], metavar="PROJECT=VERSION")
    ap.add_argument("--dry-run", action="store_true", help="resolve file names only, no download")
    args = ap.parse_args()

    data = json.loads(args.file.read_text())
    spec = data["spec"]
    if args.python:
        spec["python"] = args.python
    for s in args.set:
        k, v = s.split("=", 1)
        spec["pins"][k] = v

    old = data.get("packages", {})
    packages = {}
    for project, version in spec["pins"].items():
        links = index_links(spec["index"], project)
        fname = pick(links, project, version, spec["python"])
        url = f"{spec['index'].rstrip('/')}/{project}/{urllib.parse.quote(fname)}"
        prev = old.get(project)
        if prev and prev.get("url") == url and prev.get("hash"):
            h = prev["hash"]
            print(f"= {fname}", file=sys.stderr)
        elif args.dry_run:
            h = None
            print(f"? {fname}", file=sys.stderr)
        else:
            print(f"+ {fname} (fetching)", file=sys.stderr)
            h = prefetch(url, store_name(fname))
        packages[project] = {"version": version, "filename": fname, "url": url, "hash": h}

    data["packages"] = packages
    if not args.dry_run:
        args.file.write_text(json.dumps(data, indent=2) + "\n")
        print(f"wrote {args.file}", file=sys.stderr)
    else:
        print(json.dumps(packages, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
