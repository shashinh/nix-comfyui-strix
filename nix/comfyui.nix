# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# ComfyUI core, pinned, run from the store on the ROCm Python env.
# Structure (store layout, binary wrapper, requirements dry-run check) follows
# nixpkgs pkgs/by-name/co/comfyui/package.nix (MIT, Copyright (c) 2003-2026
# Eelco Dolstra and the Nixpkgs/NixOS contributors). nixpkgs'
# use-writable-runtime-paths.patch is not needed: the launcher always passes
# --base-directory, and in v0.46.0 the database defaults to the user dir.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeBinaryWrapper,
  python,
  pythonEnv,
  libraryPath,
  # Triton (used by torch 2.14's native ops on ROCm, e.g. in the Qwen3 text
  # encoder) compiles a small C launcher stub at first use and needs a host C
  # compiler; results are cached in TRITON_CACHE_DIR.
  cc,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "comfyui";
  version = "0.46.0";

  src = fetchFromGitHub {
    owner = "Comfy-Org";
    repo = "ComfyUI";
    tag = "v${finalAttrs.version}";
    hash = "sha256-WO3xkaRVxDbfiRJC+RfljSOOdj6CAkflgZxv4cKe4vs=";
  };

  nativeBuildInputs = [ makeBinaryWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/comfyui $out/bin
    cp -r . $out/share/comfyui
    # Upstream ships placeholder dirs; all of these live in the state dir.
    rm -rf $out/share/comfyui/{custom_nodes,input,output,models,user,temp}

    makeBinaryWrapper ${lib.getExe pythonEnv} $out/bin/comfyui \
      --add-flag "$out/share/comfyui/main.py" \
      --unset NIX_PYTHONPATH \
      --unset PYTHONPATH \
      --prefix LD_LIBRARY_PATH : "${libraryPath}" \
      --set-default ROCPROFILER_REGISTER_ENABLED 0 \
      --set-default ROCM_SDK_TARGET_FAMILY gfx1151 \
      --set-default CC ${cc}/bin/cc
    runHook postInstall
  '';

  # Every requirement of this ComfyUI release is satisfied by the env, and the
  # server starts on CPU (no GPU in the build sandbox).
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    PYTHONPATH=${pythonEnv}/${python.sitePackages} ${lib.getExe python.pkgs.pip} install \
      --break-system-packages --dry-run --no-index -r requirements.txt
    export HOME="$(mktemp -d)"
    base="$(mktemp -d)"
    "$out"/bin/comfyui --help >/dev/null
    "$out"/bin/comfyui --cpu --quick-test-for-ci --base-directory "$base" --disable-all-custom-nodes
    runHook postInstallCheck
  '';

  passthru = { inherit python pythonEnv libraryPath; };

  meta = {
    description = "Modular diffusion model GUI, API and backend (ROCm build)";
    homepage = "https://github.com/Comfy-Org/ComfyUI";
    changelog = "https://github.com/Comfy-Org/ComfyUI/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    mainProgram = "comfyui";
    platforms = [ "x86_64-linux" ];
  };
})
