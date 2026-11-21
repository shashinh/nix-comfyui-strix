# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# Wraps one stdlib-only Python script from tools/ as a command.
{
  lib,
  writeShellApplication,
  python3,
  name,
  script,
  runtimeInputs ? [ ],
  defaultManifest ? null,
}:
writeShellApplication {
  inherit name;
  runtimeInputs = runtimeInputs;
  text =
    lib.optionalString (defaultManifest != null) ''
      export COMFYUI_MODELS_MANIFEST="''${COMFYUI_MODELS_MANIFEST:-${defaultManifest}}"
    ''
    + ''
      exec ${lib.getExe python3} -I ${script} "$@"
    '';
  meta.license = lib.licenses.gpl3Plus;
}
