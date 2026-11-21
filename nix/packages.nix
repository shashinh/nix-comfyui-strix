# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# Everything the flake builds, as a function of a nixpkgs package set.
#
#   customNodes          list of derivations made with ./custom-nodes.nix
#   extraPythonPackages  ps: [ ... ] extra Python packages for ad hoc nodes
{
  pkgs,
  customNodes ? [ ],
  extraPythonPackages ? (_: [ ]),
}:
let
  inherit (pkgs) lib;

  # PyPI bump helper for the small ComfyUI companion packages nixpkgs lags on.
  bumpPypi =
    pkg: pypiName: version: sha256:
    pkg.overridePythonAttrs (_: {
      inherit version;
      src = pkgs.fetchPypi {
        pname = pypiName;
        inherit version sha256;
      };
    });

  # nixpkgs' default Python with torch/torchvision/torchaudio/triton replaced
  # by the prebuilt ROCm wheel set. Everything else comes from the binary
  # cache; packages that link or check against torch are handled below so
  # that nothing compiles.
  python = pkgs.python3.override {
    self = python;
    packageOverrides = final: prev: {
      torch-rocm = final.callPackage ./torch-rocm { };
      torch = final.torch-rocm;
      torchvision = final.torch-rocm;
      torchaudio = final.torch-rocm;
      triton = final.torch-rocm;

      # ComfyUI v0.46.0 requirements.txt pins (nixpkgs has the v0.44.0 set).
      comfyui-frontend-package =
        bumpPypi prev.comfyui-frontend-package "comfyui_frontend_package" "1.59.6"
          "68f828837a6d4c43b4f70df982452ab76aefd9108dfd70ea22cf928e9bfccdd2";
      comfyui-embedded-docs =
        bumpPypi prev.comfyui-embedded-docs "comfyui_embedded_docs" "0.5.17"
          "2e2d2e8693e47f3770595725db36aa995eed21f89bef247ab183678a040a6583";
      comfyui-workflow-templates =
        bumpPypi prev.comfyui-workflow-templates "comfyui_workflow_templates" "0.11.111"
          "10167746607dd75f50dfbedde8fb546b7c894b6c6495b84570c388f303f391fd";
      comfyui-workflow-templates-core =
        bumpPypi prev.comfyui-workflow-templates-core "comfyui_workflow_templates_core" "0.3.402"
          "e0291114dd30d9af9307d1ee160cdbc70042e04f2ef953fb955fffe191e668a8";
      comfyui-workflow-templates-json =
        bumpPypi prev.comfyui-workflow-templates-json "comfyui_workflow_templates_json" "0.1.137"
          "f7ed6e1c2f2ec35425f266502526e36ed13f461258937bde1dcc2d18f3b45dbb";
      comfyui-workflow-templates-media-assets-02 =
        bumpPypi prev.comfyui-workflow-templates-media-assets-02
          "comfyui_workflow_templates_media_assets_02"
          "0.1.34"
          "1f18bb021bbb4c2cf602b4a16d6fb44180d1fd88380bc7175c7efcaf931b922c";

      # torch appears only among their build/check inputs, not at runtime:
      # take the binary-cache builds (both are Rust) instead of rebuilding.
      safetensors = pkgs.python3Packages.safetensors;
      kornia-rs = pkgs.python3Packages.kornia-rs;

      # Pure-Python packages that depend on torch at runtime are rebuilt
      # against the wheel torch (no compilation); their test suites are
      # skipped because they would run torch in the build sandbox.
      kornia = prev.kornia.overridePythonAttrs { doCheck = false; };
      spandrel = prev.spandrel.overridePythonAttrs { doCheck = false; };
      torchsde = prev.torchsde.overridePythonAttrs { doCheck = false; };

      # nixpkgs builds comfy-kitchen's native (CUDA/HIP/CPU) extension against
      # torch, which would compile here. Use the upstream pure-Python wheel:
      # ComfyUI then uses its eager/Triton backends.
      comfy-kitchen = final.buildPythonPackage {
        pname = "comfy-kitchen";
        version = "0.2.41";
        format = "wheel";
        src = pkgs.fetchPypi {
          pname = "comfy_kitchen";
          version = "0.2.41";
          format = "wheel";
          dist = "py3";
          python = "py3";
          sha256 = "19bdd7f8aaa35c512ef69393038ddca51f030bcabf6a7694fdf1660bcae8c66a";
        };
        dependencies = [ final.torch ];
        pythonImportsCheck = [ ];
        meta.license = lib.licenses.asl20;
      };
    };
  };

  torch-rocm = python.pkgs.torch-rocm;

  customNodeLib = import ./custom-nodes.nix { inherit pkgs; };
  customNodesTree = customNodeLib.mkTree customNodes;

  appDependencies =
    ps:
    with ps;
    [
      aiohttp
      alembic
      av
      blake3
      comfy-aimdo
      comfy-angle
      comfy-kitchen
      comfyui-embedded-docs
      comfyui-frontend-package
      comfyui-workflow-templates
      einops
      filelock
      kornia
      numpy
      pillow
      psutil
      pydantic
      pydantic-settings
      pyopengl
      pyyaml
      requests
      safetensors
      scipy
      sentencepiece
      simpleeval
      spandrel
      sqlalchemy
      tokenizers
      torch
      torchaudio
      torchsde
      torchvision
      tqdm
      transformers
      yarl
    ]
    ++ lib.concatMap (n: n.passthru.pythonDeps ps) customNodes
    ++ extraPythonPackages ps;

  pythonEnv = python.withPackages appDependencies;

  # Libraries ComfyUI, its nodes and common custom nodes dlopen at runtime
  # (OpenCV/GL/X11 for preview and image nodes).
  runtimeLibraryPath = lib.makeLibraryPath (
    with pkgs;
    [
      stdenv.cc.cc.lib
      zlib
      glib
      libGL
      libglvnd
      libx11
      libxext
      libxrender
      libxcb
      libsm
      libice
    ]
  );

  libraryPath = "${torch-rocm.libraryPath}:${runtimeLibraryPath}";

  comfyui = pkgs.callPackage ./comfyui.nix {
    inherit python pythonEnv libraryPath;
    inherit (pkgs.stdenv) cc;
  };

  models = import ./models.nix;

  comfyui-models = pkgs.callPackage ./tools-pkgs.nix {
    name = "comfyui-models";
    script = ../tools/comfyui-models.py;
    runtimeInputs = [ pkgs.curl ];
    defaultManifest = pkgs.writeText "comfyui-models.json" (builtins.toJSON models.smoke);
  };

  run-workflow = pkgs.callPackage ./tools-pkgs.nix {
    name = "run-workflow";
    script = ../tools/run-workflow.py;
  };

  update-wheels = pkgs.writeShellApplication {
    name = "update-wheels";
    runtimeInputs = [
      pkgs.python3
      pkgs.nix
    ];
    text = ''
      # run from the repository root, or set UPDATE_WHEELS_FILE
      exec python3 -I ${./torch-rocm/update-wheels.py} \
        --file "''${UPDATE_WHEELS_FILE:-nix/torch-rocm/wheels.json}" "$@"
    '';
    meta.license = lib.licenses.gpl3Plus;
  };

  mkLauncher =
    {
      manifest ? models.smoke,
      nodes ? customNodesTree,
    }:
    pkgs.callPackage ./launcher.nix {
      inherit comfyui comfyui-models;
      customNodesTree = nodes;
      manifest = pkgs.writeText "comfyui-models.json" (builtins.toJSON manifest);
    };

  comfyui-strix = mkLauncher { };
in
{
  inherit
    python
    pythonEnv
    torch-rocm
    comfyui
    comfyui-models
    run-workflow
    update-wheels
    comfyui-strix
    mkLauncher
    customNodeLib
    libraryPath
    ;
}
