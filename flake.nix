# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
{
  description = "nix-comfyui-strix: ComfyUI with prebuilt ROCm PyTorch for AMD Strix Halo (gfx1151) on NixOS";

  # Consumers should make this follow their own nixpkgs so store paths are shared.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d5cc6833999746cffdfe0598f7bc801a57b887a9";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      strix = import ./nix/packages.nix { inherit pkgs; };
    in
    {
      packages.${system} = {
        inherit (strix)
          torch-rocm
          python
          pythonEnv
          comfyui
          comfyui-strix
          comfyui-models
          run-workflow
          update-wheels
          ;
        default = strix.comfyui-strix;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${strix.comfyui-strix}/bin/comfyui-strix";
          meta.description = "Run ComfyUI (ROCm, gfx1151) in the foreground";
        };
        comfyui-models = {
          type = "app";
          program = "${strix.comfyui-models}/bin/comfyui-models";
          meta.description = "Check or fetch the declared models";
        };
        run-workflow = {
          type = "app";
          program = "${strix.run-workflow}/bin/run-workflow";
          meta.description = "Submit an API-format workflow to ComfyUI and save its outputs";
        };
      };

      # Overlay-free builder so a consumer can rebuild everything on its own
      # nixpkgs: `lib.mkPackages pkgs`.
      lib.mkPackages = pkgs: import ./nix/packages.nix { inherit pkgs; };
      # Curated custom node from a pinned source; see nix/custom-nodes.nix.
      lib.mkCustomNode = pkgs: (import ./nix/custom-nodes.nix { inherit pkgs; }).mkCustomNode;

      nixosModules.default = import ./nix/module.nix { inherit self; };
      nixosModules.comfyui-strix = self.nixosModules.default;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.python3
          pkgs.jq
          pkgs.curl
          strix.update-wheels
          strix.comfyui-models
          strix.run-workflow
        ];
      };

      checks.${system} = import ./nix/checks.nix { inherit self pkgs nixpkgs; };

      formatter.${system} = pkgs.nixfmt;
    };
}
