# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# `nix flake check`: evaluate the NixOS module in minimal configurations and
# build only the generated unit files and configs (no VM, no system build).
{
  self,
  pkgs,
  nixpkgs,
}:
let
  evalWith =
    extra:
    nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.default
        (
          { config, ... }:
          {
            boot.isContainer = true;
            system.stateVersion = config.system.nixos.release;
            users.users.alice.isNormalUser = true;
            services.llama-swap = {
              enable = true;
              port = 8686;
              settings.models.dummy-llm = {
                cmd = "sleep infinity";
                proxy = "http://127.0.0.1:9";
              };
            };
            services.comfyui-strix = {
              enable = true;
              user = "alice";
              llamaSwap.enable = true;
              llamaSwap.sets.image = "dummy-llm & comfy";
              expose.enable = true;
              expose.interfaces = [
                "eth0"
                "tailscale0"
              ];
            };
          }
        )
        extra
      ];
    };

  unitsOf =
    name: sys:
    let
      u = sys.config.systemd.units;
    in
    pkgs.linkFarm name (
      [
        {
          name = "comfyui.service";
          path = u."comfyui.service".unit;
        }
        {
          name = "llama-swap.service";
          path = u."llama-swap.service".unit;
        }
        {
          name = "nginx.service";
          path = u."nginx.service".unit;
        }
        {
          name = "llama-swap-shim";
          path = sys.config.services.comfyui-strix.internal.shim;
        }
        {
          name = "comfyui-hold";
          path = sys.config.services.comfyui-strix.internal.hold;
        }
        {
          name = "polkit-rules";
          path = pkgs.writeText "polkit-rules" sys.config.security.polkit.extraConfig;
        }
      ]
      ++ pkgs.lib.optionals (u ? "comfyui-activate.socket") [
        {
          name = "comfyui-activate.socket";
          path = u."comfyui-activate.socket".unit;
        }
        {
          name = "comfyui-activate.service";
          path = u."comfyui-activate.service".unit;
        }
      ]
    );
in
{
  module-polkit = unitsOf "comfyui-strix-module-polkit" (evalWith { });
  module-socket = unitsOf "comfyui-strix-module-socket" (evalWith {
    services.comfyui-strix.llamaSwap.mode = "socket";
  });

  tools = pkgs.runCommandLocal "comfyui-strix-tools-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp ${../tools/comfyui-models.py} comfyui-models.py
    cp ${../tools/run-workflow.py} run-workflow.py
    cp ${./torch-rocm/update-wheels.py} update-wheels.py
    python3 -m py_compile comfyui-models.py run-workflow.py update-wheels.py
    for f in ${../workflows}/*.json; do python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f"; done
    touch $out
  '';
}
