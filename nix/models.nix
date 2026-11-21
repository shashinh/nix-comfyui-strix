# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# Declared models. Each entry: path (relative to the models dir), url (pinned
# to a repository revision), sha256 (hex), size (bytes), license, source.
# Nothing here is fetched by Nix: `comfyui-models fetch` downloads on request,
# `comfyui-models check` runs before ComfyUI starts. Undeclared files in the
# models dir are ignored.
let
  # Comfy-Org/Flux-2-Klein-4B, repackaged for ComfyUI (checked 2026-11-20).
  kleinRev = "5b3abca5c0dc1ecd4eaf3340868d09063fc1c965";
  klein = file: "https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/${kleinRev}/split_files/${file}";
in
{
  # FLUX.2 [klein] 4B (distilled), the files the two smoke-test workflows use.
  # Total 16,132,299,052 bytes (~16.1 GB).
  smoke = [
    {
      path = "diffusion_models/flux-2-klein-4b.safetensors";
      url = klein "diffusion_models/flux-2-klein-4b.safetensors";
      sha256 = "ec3d4e733a771f61c052fb4856c48b336c55eaf2c65487c2a1faeb9bbda7a343";
      size = 7751105712;
      license = "Apache-2.0";
      source = "black-forest-labs/FLUX.2-klein-4B via Comfy-Org/Flux-2-Klein-4B";
    }
    {
      path = "text_encoders/qwen_3_4b.safetensors";
      url = klein "text_encoders/qwen_3_4b.safetensors";
      sha256 = "6c671498573ac2f7a5501502ccce8d2b08ea6ca2f661c458e708f36b36edfc5a";
      size = 8044982048;
      license = "Apache-2.0";
      source = "Qwen3-4B text encoder via Comfy-Org/Flux-2-Klein-4B";
    }
    {
      path = "vae/flux2-vae.safetensors";
      url = klein "vae/flux2-vae.safetensors";
      sha256 = "868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3";
      size = 336211292;
      license = "Apache-2.0";
      source = "FLUX.2 VAE via Comfy-Org/Flux-2-Klein-4B";
    }
  ];
}
