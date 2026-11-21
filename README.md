# nix-comfyui-strix

ComfyUI for AMD Strix Halo (Ryzen AI Max+ 395, Radeon 8060S, `gfx1151`) on
NixOS, packaged as a flake: pinned ComfyUI core, AMD's prebuilt ROCm PyTorch
wheels (nothing compiled), a launcher, a model check/fetch tool and a NixOS
module that runs ComfyUI on demand and, optionally, lets
[llama-swap](https://github.com/mostlygeek/llama-swap) start and stop it so the
GPU is shared with LLMs.

It is for people who run NixOS on a Strix Halo machine and want ComfyUI as a
reproducible system service rather than a hand-made venv. Other gfx targets
would need a different wheel set (see *Bumping*); nothing else is
Strix-specific.

## What it pins

| component | version | source |
| --- | --- | --- |
| ComfyUI | v0.46.0 (`a277b5bf`) | github.com/Comfy-Org/ComfyUI |
| frontend / templates / embedded docs | 1.59.6 / 0.11.111 / 0.5.17 | PyPI (as required by v0.46.0) |
| PyTorch | 2.14.0+rocm10.1.0 | stable.repo.amd.com/rocm/whl-next, `cp314` |
| torchvision / torchaudio / triton | 0.29.0a0 / 2.11.0.3 / 3.8.0+git669b31ac (all +rocm10.1.0) | same |
| ROCm SDK wheels | rocm-sdk-core/libraries/device-gfx1151 10.1.0 | same |
| Python | 3.14 (nixpkgs default) | nixpkgs |
| nixpkgs | `d5cc6833` | follow your own with `inputs.nixpkgs.follows` |

The twelve wheels are listed with URL and sha256 in
`nix/torch-rocm/wheels.json` (about 1.6 GB of downloads). The launcher's
closure is 8.4 GiB, 6.6 GiB of it the installed ROCm/torch wheel set. Inside
the 10.1 SDK the HIP runtime reports itself as 7.16.

### How the Python env is built

The nixpkgs Python set with `torch`, `torchvision`, `torchaudio` and `triton`
replaced by one derivation that `pip install --no-deps`es the pinned wheels
(no patchelf: the libraries are found through `LD_LIBRARY_PATH`, which the
ComfyUI wrapper sets). Everything else comes from the NixOS binary cache:

- `safetensors` and `kornia-rs` only list torch as a build/check input, so the
  cached builds are used as-is;
- `kornia`, `spandrel`, `torchsde` (pure Python, torch at runtime) are rebuilt
  against the wheel torch with their test suites off - a few seconds, no
  compiler;
- `comfy-kitchen` is the upstream pure-Python wheel instead of nixpkgs'
  native build (ComfyUI uses its `eager` backend);
- the ComfyUI companion packages are bumped to the versions v0.46.0 pins.

At runtime Triton (which torch 2.14 uses for some native ops on ROCm, e.g. in
the Qwen3 text encoder) compiles a tiny C launcher stub on first use, so the
wrapper sets `CC` to nixpkgs' `stdenv.cc`; the stub is cached in
`<state>/cache/triton`. This is the only compiler involvement: a small C stub,
compiled once at runtime.

`nix build .#comfyui --dry-run` shows only fetches, those pure-Python builds,
the wheel install and the env.

## Quick start

```sh
nix run github:shashinh/nix-comfyui-strix -- --help
nix run github:shashinh/nix-comfyui-strix#comfyui-models -- fetch   # ~16.1 GB, asks first
nix run github:shashinh/nix-comfyui-strix                           # http://127.0.0.1:8188
```

The launcher (`comfyui-strix`) takes:

| flag | env | default |
| --- | --- | --- |
| `--state-dir` | `COMFYUI_STATE_DIR` | `$XDG_STATE_HOME/comfyui-strix` (`~/.local/state/comfyui-strix`) |
| `--models-dir` | `COMFYUI_MODELS_DIR` | `/data/models/comfyui` |
| `--listen` / `--port` | `COMFYUI_LISTEN` / `COMFYUI_PORT` | `127.0.0.1` / `8188` |
| `--skip-model-check` | `COMFYUI_SKIP_MODEL_CHECK=1` | check runs |
| ComfyUI flags | `COMFYUI_ARGS` (replaces) | `--disable-mmap --bf16-vae --highvram --disable-partner-nodes` |

Anything after `--` is passed to ComfyUI. It creates
`<state>/{user,input,output,temp,custom_nodes,cache}`, writes
`<state>/extra_model_paths.yaml`, runs the model check and execs ComfyUI in the
foreground.

## NixOS module

```nix
# flake.nix of your system
inputs.comfyui-strix = {
  url = "github:shashinh/nix-comfyui-strix";
  inputs.nixpkgs.follows = "nixpkgs";
};

# a NixOS module
{ inputs, ... }: {
  imports = [ inputs.comfyui-strix.nixosModules.default ];
  services.comfyui-strix = {
    enable = true;
    user = "alice";                 # an existing user
    llamaSwap.enable = true;        # needs services.llama-swap.enable
    llamaSwap.sets.image = "gemma4 & comfy";   # matrix vars from your llama-swap config
    expose.enable = true;
    expose.interfaces = [ "enp1s0" "tailscale0" ];
  };
}
```

| option | default | meaning |
| --- | --- | --- |
| `enable` | `false` | defines `comfyui.service` (not started at boot) |
| `user` | - | existing user it runs as; owns the two dirs below |
| `stateDir` | `/data/comfyui` | user data, inputs, outputs, ad hoc nodes, caches (created by tmpfiles) |
| `modelsDir` | `/data/models/comfyui` | `--models-directory` (created by tmpfiles) |
| `port`, `listenAddress` | `8188`, `127.0.0.1` | ComfyUI itself |
| `extraArgs` | `--disable-mmap --bf16-vae --highvram --disable-partner-nodes` | complete ComfyUI flag list |
| `environment` | `{}` | extra env; wins over the launcher's defaults |
| `customNodes` | `[]` | curated nodes from the store (`inputs.comfyui-strix.lib.mkCustomNode pkgs { ... }`) |
| `extraPythonPackages` | `ps: []` | Python deps for ad hoc nodes (no runtime pip) |
| `models` | klein 4B smoke set | declared models checked before every start; may be `[]` |
| `llamaSwap.enable` | `false` | register as llama-swap's `comfyui_auto` |
| `llamaSwap.mode` | `"polkit"` | `"polkit"` or `"socket"`, see below |
| `llamaSwap.ttl` | `1800` | idle seconds before llama-swap stops ComfyUI |
| `llamaSwap.unloadTimeout` | `30` | seconds llama-swap waits for the stop |
| `llamaSwap.matrixVar` | `"comfy"` | matrix var name for `comfyui_auto` |
| `llamaSwap.sets` | `{}` | matrix sets to add (none: ComfyUI only runs alone) |
| `llamaSwap.evictCost` | `null` | matrix `evict_costs` entry |
| `llamaSwap.socketPort`, `socketIdleSeconds` | `8189`, `5` | socket mode only |
| `expose.enable` | `false` | nginx vhost publishing only `/comfyui/` |
| `expose.port` | `8190` | |
| `expose.interfaces` | `["tailscale0"]` | firewall opened on these only |
| `expose.openFirewall` | `true` | |

The unit runs as `user` with groups `render` and `video`, `ProtectHome=tmpfs`,
`ProtectSystem=strict`, write access only to `stateDir` and `modelsDir`, and
the usual kernel/namespace hardening. `MemoryDenyWriteExecute` is deliberately
not set (ROCm and Triton JIT-compile kernels). `ExecStartPre` is
`comfyui-models check`; `ExecStartPost` waits until ComfyUI answers HTTP, so
`systemctl start comfyui` returns when it is ready.

## Models

Models never enter the Nix store and are never downloaded at build or start.

- **Declared** models (`models` option, default in `nix/models.nix`) have a
  path under `modelsDir`, a pinned URL, sha256, size and license.
  `comfyui-models check` (run before every start) lists missing ones with the
  command that fetches them and fails; files it does not declare are ignored.
  `comfyui-models fetch` prints total size and destination, asks, downloads
  resumably and verifies sha256. `verify` re-hashes, `list` shows licenses.
- **Ad hoc** models are just files you put in `modelsDir`.

Default (smoke-test) set, from `Comfy-Org/Flux-2-Klein-4B` at `5b3abca5`, all
Apache-2.0:

| file | size |
| --- | --- |
| `diffusion_models/flux-2-klein-4b.safetensors` (distilled, bf16) | 7.75 GB |
| `text_encoders/qwen_3_4b.safetensors` | 8.04 GB |
| `vae/flux2-vae.safetensors` | 0.34 GB |

## Workflows and custom nodes

- Your workflows live in `<stateDir>/user/default/workflows`, where the web app
  saves them. Nothing in the flake or module declares or touches them.
- `workflows/klein-t2i.json` and `workflows/klein-edit.json` are API-format
  test fixtures (converted from the official ComfyUI templates
  `image_flux2_klein_text_to_image` and `image_flux2_klein_image_edit_4b_distilled`,
  templates v0.11.111; core nodes only).
- `run-workflow` submits an API-format workflow, overrides prompt / seed /
  input image / any input, waits, saves outputs and prints total time and
  seconds per step.
- Ad hoc custom nodes: `<stateDir>/custom_nodes`. Their Python dependencies
  come from `extraPythonPackages`; there is no pip at runtime.
- Curated custom nodes: pinned sources built with `lib.mkCustomNode` (see
  `nix/custom-nodes.nix`), listed in `customNodes`, loaded from the store via
  the generated `extra_model_paths.yaml`. The default list is empty; the smoke
  workflows need only core nodes.

## llama-swap arbitration

With `llamaSwap.enable` the module adds llama-swap's reserved model
`comfyui_auto`: its `cmd` is a small shim, `proxy` points at ComfyUI,
`checkEndpoint: /`, `unlisted: true`. ComfyUI is then reachable at
`http://<llama-swap>/comfyui/`; any request there that is not a static asset,
`/ws` or `/api/jobs` (including simply opening the page) starts it, the
matrix sets decide what may stay loaded with it, and `ttl` stops it when idle.

ComfyUI is not llama-swap's child: llama-swap's NixOS service is
`DynamicUser`, `PrivateUsers`, `ProtectHome`, `MemoryDenyWriteExecute`. Two
ways to bridge that:

- `mode = "polkit"` (default): the shim runs `systemctl start comfyui.service`,
  blocks while it is active, and llama-swap's `cmdStop` runs
  `systemctl stop comfyui.service`. A polkit rule allows exactly start/stop/
  restart of that one unit for the `llama-swap` user and the service user.
- `mode = "socket"`: no D-Bus. A socket-activated `systemd-socket-proxyd` on
  `socketPort` starts `comfyui.service` on connection; the shim keeps it alive
  with a request every 2 s; when the shim exits the proxy idles out after
  `socketIdleSeconds` and the `StopWhenUnneeded` unit stops. Use it if the
  polkit route does not work under llama-swap's sandbox.

Known gaps (llama-swap v268): an LLM request that needs the GPU while a render
runs evicts ComfyUI mid-render (an upstream fix, PR #1253, was open as of 2026-11-20); WebSocket traffic
does not count as activity, so watching a long render counts as idle. For long
jobs use **`comfyui-hold`**: it pauses llama-swap (`POST /api/models/pause`,
which unloads everything and makes llama-swap answer 503, `/comfyui/`
included), runs ComfyUI directly on `127.0.0.1:<port>`, and resumes llama-swap
when you press Ctrl-C.

## Network exposure

`expose.enable` adds an nginx vhost on `expose.port` that maps every path to
llama-swap's `/comfyui/` route (WebSockets included), and opens that port on
`expose.interfaces` only. It proxies `$request_uri` verbatim: the web app
saves workflows to `/api/userdata/workflows%2F<name>.json`, and a normalised
(decoded) path would break that. Remote use therefore still starts ComfyUI on demand
and goes through arbitration, and no LLM endpoint is published.

**ComfyUI has no authentication.** Anyone who can reach the port can run
workflows, upload files and, through custom nodes, execute code as the service
user. The sandbox limits that user to `stateDir` and `modelsDir` (home
directories are hidden), but only expose it on networks you trust (a LAN you
control, your tailnet).

## Tuning flags and their evidence

| setting | status |
| --- | --- |
| `--disable-mmap` | default, carried over from earlier Strix Halo setups; not benchmarked here |
| `--bf16-vae` | default, same; not benchmarked here |
| `--highvram` | default; "CPU" memory is the same RAM as GPU memory on this APU, so offloading buys nothing; not benchmarked here |
| `--disable-partner-nodes` | default; hides the paid hosted-API nodes |
| `MIOPEN_SEARCH_CUTOFF=1` | default; shortens MIOpen's first-run kernel search |
| `MIOPEN_USER_DB_PATH`, `MIOPEN_CUSTOM_CACHE_DIR`, `TRITON_CACHE_DIR`, `TORCHINDUCTOR_CACHE_DIR`, `HF_HOME` | in `<stateDir>/cache` so kernels are reused across starts |
| `ROCPROFILER_REGISTER_ENABLED=0` | set by the wrapper (as in utensils/comfyui-nix) |
| `HSA_OVERRIDE_GFX_VERSION`, `MIOPEN_FIND_MODE`, `COMFYUI_ENABLE_MIOPEN` | deliberately unset: gfx1151 is native in these wheels |
| `--use-ck-attention`, `--gpu-only` and similar | untested; candidates for a later benchmark |

## Measured smoke-test timings

Indicative single runs on 2026-11-20, not a benchmark: Radeon 8060S, 108 GB
GTT, default flags, a small llama.cpp model resident on the same GPU, idle
otherwise. FLUX.2 klein 4B distilled (bf16), 4 steps, euler, cfg 1,
1024x1024. Total = submit to finished, as measured by `run-workflow`;
s/step from the sampler's progress events.

| workflow | run | total | s/step |
| --- | --- | --- | --- |
| `klein-t2i.json` | first (loads text encoder 7.7 GB + model 7.4 GB, Triton stub) | 14.8 s | 1.58 |
| `klein-t2i.json` | warm, new seed | 7.4 s | 1.59 |
| `klein-edit.json` (1 reference image, 1 MP) | first edit | 18.2 s | 3.66 |
| `klein-edit.json` | warm, new seed | 15.8 s | 3.69 |

Server start to first HTTP answer: about 8 s.

## Bumping

- **Wheels:** `nix develop`, then `update-wheels --set torch=<ver> ...` (edits
  the `spec` in `nix/torch-rocm/wheels.json` and prefetches every file, so
  the next build downloads nothing). Check the new torch's
  `Requires-Dist` for the matching triton / rocm versions. Since torch 2.15
  the ROCm libraries may be split differently; read the wheel metadata.
- **ComfyUI:** change `version` and `hash` in `nix/comfyui.nix`, then compare
  its `requirements.txt` with the bumps at the top of `nix/packages.nix`
  (frontend, templates and their sub-packages, embedded docs, comfy-kitchen)
  and update those. The build's install check fails if a requirement is not
  met.
- Always `nix build .#comfyui --dry-run` first and make sure no torch, ROCm
  or LLVM derivation is going to be compiled.

## Acknowledgements

- nixpkgs `comfyui` package (MIT, Copyright (c) 2003-2026 Eelco Dolstra and
  the Nixpkgs/NixOS contributors): the store layout, wrapper and
  requirements-check approach in `nix/comfyui.nix` and the companion-package
  expressions this flake overrides.
- [hellas-ai/nix-strix-halo](https://github.com/hellas-ai/nix-strix-halo):
  showed that AMD's TheRock wheels work on NixOS when installed with
  `pip --no-deps --target`, left un-patchelf'd and given `LD_LIBRARY_PATH`.
  That repository declares no license; no code was copied from it.
- [utensils/comfyui-nix](https://github.com/utensils/comfyui-nix) (MIT): a
  second reference for ROCm ComfyUI on a 395 (`ROCPROFILER_REGISTER_ENABLED=0`).
- ComfyUI's official workflow templates (Comfy-Org/workflow_templates, MIT)
  for the smoke-test graphs.

## License

nix-comfyui-strix is Copyright (C) 2026 Shashin Halalingaiah.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

ComfyUI itself is GPL-3.0. The ROCm/PyTorch wheels and the models are fetched
from their publishers at build or fetch time, not redistributed by this
repository; each is under its own license (PyTorch BSD-3-Clause, ROCm mostly
MIT, the default models Apache-2.0).
