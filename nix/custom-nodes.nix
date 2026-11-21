# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# Curated ComfyUI custom nodes: pinned source -> store directory, Python
# dependencies from nixpkgs, loaded through extra_model_paths.yaml
# (`custom_nodes:` key) next to the mutable <state>/custom_nodes.
#
# Example (in a consumer, or in the module's `customNodes` option):
#
#   strix.customNodeLib.mkCustomNode {
#     pname = "ComfyUI-Example";          # directory name ComfyUI sees
#     version = "1.2.3";
#     src = pkgs.fetchFromGitHub { owner = "..."; repo = "..."; rev = "..."; hash = "..."; };
#     pythonDeps = ps: [ ps.opencv4 ];    # added to the ComfyUI Python env
#   }
#
# Store nodes are read-only: a node that writes into its own directory at
# runtime is not a good candidate and belongs in <state>/custom_nodes instead.
{ pkgs }:
{
  mkCustomNode =
    {
      pname,
      version,
      src,
      pythonDeps ? (_: [ ]),
      license ? null,
    }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "comfyui-node-${pname}";
      inherit version src;
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        cp -r . $out
        runHook postInstall
      '';
      passthru = {
        inherit pythonDeps;
        nodeName = pname;
      };
      meta = pkgs.lib.optionalAttrs (license != null) { inherit license; };
    };

  # One directory with a subdirectory (symlink) per node.
  mkTree =
    nodes:
    pkgs.linkFarm "comfyui-strix-custom-nodes" (
      map (n: {
        name = n.passthru.nodeName;
        path = n;
      }) nodes
    );
}
