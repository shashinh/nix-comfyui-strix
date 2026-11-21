# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# Prebuilt PyTorch + ROCm (TheRock) wheels for one GPU target, installed as a
# single Python package that stands in for torch, torchvision, torchaudio and
# triton in a nixpkgs Python set. Nothing here is compiled.
#
# Approach (not code) learned from hellas-ai/nix-strix-halo, which showed that
# these wheels work when installed with `pip install --no-deps --target`, left
# un-patchelf'd and given their libraries through LD_LIBRARY_PATH. That repo
# declares no license, so nothing was copied from it; this file is written
# from scratch.
{
  lib,
  stdenv,
  fetchurl,
  python,
  buildPythonPackage,
  pip,
  setuptools,
  wheel,
  filelock,
  fsspec,
  jinja2,
  networkx,
  numpy,
  pillow,
  sympy,
  typing-extensions,
  zlib,
  zstd,
  ncurses,
  numactl,
  libffi,
  openssl,
  libxml2,
  expat,
  libxcrypt,
  libdrm,
  pciutils,
  ocl-icd,
  elfutils,
  wheelsFile ? ./wheels.json,
}:

let
  pins = lib.importJSON wheelsFile;
  inherit (pins.spec) target;
  pkgsByName = pins.packages;

  version = pkgsByName.torch.version;

  wheels = lib.mapAttrsToList (_: p: {
    inherit (p) filename;
    src = fetchurl {
      inherit (p) url hash;
      # '+' is not allowed in store path names
      name = lib.replaceStrings [ "+" ] [ "_" ] p.filename;
    };
  }) pkgsByName;

  # Host libraries the wheels dlopen/link but do not bundle.
  runtimeLibraries = [
    stdenv.cc.cc.lib
    zlib
    zstd
    ncurses
    numactl
    libffi
    openssl
    libxml2
    expat
    libxcrypt
    libdrm
    pciutils
    ocl-icd
    elfutils
  ];

  # Directories inside site-packages holding the bundled ROCm/torch libraries.
  bundledLibDirs = [
    "_rocm_sdk_core/lib"
    "_rocm_sdk_core/lib64"
    "_rocm_sdk_core/lib/host-math/lib"
    "_rocm_sdk_core/lib/llvm/lib"
    "_rocm_sdk_core/lib/rocm_sysdeps/lib"
    "_rocm_sdk_libraries/lib"
    "torch/lib"
    "torchaudio/lib"
    "triton/backends/amd/lib"
  ];

  libraryPathFor =
    site: lib.concatStringsSep ":" ([ (lib.makeLibraryPath runtimeLibraries) ] ++ map (d: "${site}/${d}") bundledLibDirs);
in
buildPythonPackage (finalAttrs: {
  pname = "torch-rocm-${target}";
  inherit version;
  pyproject = false;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # These ELF files are $ORIGIN-linked and some have unusual segment layouts;
  # patchelf corrupts them. Libraries are found through LD_LIBRARY_PATH instead.
  dontPatchELF = true;
  dontAutoPatchelf = true;
  dontStrip = true;
  # The Python fixup hooks would try to byte-compile and wrap ~10 GB of files.
  dontUsePythonRecompileBytecode = true;

  nativeBuildInputs = [
    pip
    setuptools
    wheel
  ];

  dependencies = [
    filelock
    fsspec
    jinja2
    networkx
    numpy
    pillow
    setuptools
    sympy
    typing-extensions
  ];

  env = {
    LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibraries;
    # The `rocm` meta package is an sdist whose setup.py would otherwise run
    # `offload-arch` to pick the device package.
    ROCM_SDK_TARGET_FAMILY = target;
  };

  installPhase = ''
    runHook preInstall

    site="$out/${python.sitePackages}"
    house="$TMPDIR/wheelhouse"
    mkdir -p "$site" "$house"
    ${lib.concatMapStringsSep "\n" (w: ''cp ${w.src} "$house/${w.filename}"'') wheels}

    export HOME="$TMPDIR"
    python -m pip install \
      --no-index --no-deps --no-build-isolation --no-cache-dir \
      --disable-pip-version-check --no-compile \
      --target "$site" "$house"/*

    # pip --target also drops console scripts into $site/bin; keep them in $out/bin.
    if [ -d "$site/bin" ]; then
      mkdir -p "$out/bin"
      mv "$site/bin/"* "$out/bin/" || true
      rmdir "$site/bin" || true
    fi

    # Packages built against this one (kornia, spandrel, custom nodes, ...)
    # import torch in their import checks; give their builds the library path.
    mkdir -p "$out/nix-support"
    cat > "$out/nix-support/setup-hook" <<EOF
    export LD_LIBRARY_PATH="${libraryPathFor "$out/${python.sitePackages}"}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    EOF

    runHook postInstall
  '';

  # Import in the build sandbox (no GPU): proves the wheel set is complete and
  # the host libraries resolve. (buildPythonPackage derives doInstallCheck
  # from doCheck.)
  doCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export LD_LIBRARY_PATH="${libraryPathFor "$out/${python.sitePackages}"}"
    export PYTHONPATH="$out/${python.sitePackages}:$PYTHONPATH"
    export HOME="$TMPDIR"
    python -c 'import torch, torchvision, torchaudio; print(torch.__version__, torch.version.hip, torchvision.__version__, torchaudio.__version__)'
    runHook postInstallCheck
  '';

  passthru = {
    inherit pins target;
    wheelCount = builtins.length wheels;
    # Value for LD_LIBRARY_PATH when running Python with this package.
    libraryPath = libraryPathFor "${finalAttrs.finalPackage}/${python.sitePackages}";
    # Attributes nixpkgs expressions read from `torch`.
    cudaSupport = false;
    rocmSupport = true;
    cudaCapabilities = [ ];
    gpuTargets = [ target ];
    rocmPackages = { };
    cxxdev = finalAttrs.finalPackage;
  };

  meta = {
    description = "Prebuilt PyTorch ${version} wheels with ROCm (TheRock) for ${target}";
    homepage = "https://github.com/ROCm/TheRock";
    # PyTorch is BSD-3-Clause; the ROCm SDK wheels are mostly MIT with
    # assorted permissive components. Fetched from AMD, not redistributed.
    license = with lib.licenses; [
      bsd3
      mit
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
