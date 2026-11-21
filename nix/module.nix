# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Shashin Halalingaiah
#
# NixOS module: services.comfyui-strix.
#
# comfyui.service runs ComfyUI as an existing user, on demand (not started at
# boot). With llamaSwap.enable it becomes llama-swap's reserved `comfyui_auto`
# model, so llama-swap starts/stops it and arbitrates the GPU against LLMs.
# With expose.enable an nginx vhost publishes only llama-swap's /comfyui/
# route to the LAN/Tailscale.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.comfyui-strix;
  ls = config.services.llama-swap;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    types
    ;

  strix = import ./packages.nix {
    inherit pkgs;
    inherit (cfg) customNodes extraPythonPackages;
  };
  launcher = strix.mkLauncher { manifest = cfg.models; };
  manifestFile = pkgs.writeText "comfyui-models.json" (builtins.toJSON cfg.models);

  systemctl = "${config.systemd.package}/bin/systemctl";
  curl = lib.getExe pkgs.curl;
  unit = "comfyui.service";
  probeHost =
    if
      lib.elem cfg.listenAddress [
        "0.0.0.0"
        "::"
        ""
      ]
    then
      "127.0.0.1"
    else
      cfg.listenAddress;
  comfyUrl = "http://${probeHost}:${toString cfg.port}";
  llamaSwapUrl = "http://127.0.0.1:${toString ls.port}";

  waitReady = pkgs.writeShellScript "comfyui-wait-ready" ''
    # Hold the unit in "activating" until ComfyUI answers HTTP, so that
    # `systemctl start` (and anything ordered After= it) means "ready".
    until ${curl} -fsS -o /dev/null --max-time 5 ${comfyUrl}/; do sleep 1; done
  '';

  # Foreground process llama-swap runs as comfyui_auto's `cmd`. It is not
  # ComfyUI itself: llama-swap's sandbox (DynamicUser, PrivateUsers,
  # ProtectHome, MemoryDenyWriteExecute) is unsuitable for a ROCm/torch
  # process, so ComfyUI runs as its own unit and this shim mirrors it.
  # The shim reads COMFYUI_SYSTEMCTL / COMFYUI_UNIT only so that it can be
  # exercised against a user-level test unit; in the service they are unset.
  shim =
    {
      mode ? cfg.llamaSwap.mode,
    }:
    let
      sleep = "${pkgs.coreutils}/bin/sleep";
      seq = "${pkgs.coreutils}/bin/seq";
    in
    if mode == "polkit" then
      pkgs.writeShellScript "comfyui-llama-swap-shim" ''
        # Start comfyui.service (allowed for this caller by polkit), block while
        # it runs, stop it on SIGTERM/SIGINT. llama-swap normally stops it via
        # cmdStop, after which the loop below ends on its own.
        sc=''${COMFYUI_SYSTEMCTL:-${systemctl}}
        unit=''${COMFYUI_UNIT:-${unit}}
        stop() { $sc --no-ask-password stop "$unit"; exit 0; }
        trap stop TERM INT
        $sc --no-ask-password start "$unit" &
        if ! wait $!; then
          echo "comfyui-strix shim: could not start $unit; see journalctl -u $unit" >&2
          exit 1
        fi
        while $sc --quiet is-active "$unit"; do ${sleep} 2 & wait $!; done
        echo "comfyui-strix shim: $unit is no longer active" >&2
        exit 1
      ''
    else
      pkgs.writeShellScript "comfyui-llama-swap-shim" ''
        # Socket mode: no D-Bus. Each request to the activation socket starts
        # comfyui.service (via comfyui-activate.service); the activator exits
        # ${toString cfg.llamaSwap.socketIdleSeconds}s after its last connection and comfyui.service, being
        # StopWhenUnneeded, stops with it. This shim keeps it alive with a
        # periodic request and, on SIGTERM, waits until ComfyUI is gone so
        # llama-swap does not load the next model too early.
        act=''${COMFYUI_ACTIVATE_URL:-http://127.0.0.1:${toString cfg.llamaSwap.socketPort}/}
        comfy=''${COMFYUI_URL:-${comfyUrl}/}
        stop() {
          for _ in $(${seq} 1 ${toString (cfg.llamaSwap.unloadTimeout - 2)}); do
            ${curl} -s -o /dev/null --max-time 1 "$comfy" || exit 0
            ${sleep} 1
          done
          exit 0
        }
        trap stop TERM INT
        fails=0
        while :; do
          if ${curl} -fsS -o /dev/null --max-time 600 "$act"; then
            fails=0
          else
            fails=$((fails + 1))
            if [ "$fails" -ge 3 ]; then
              echo "comfyui-strix shim: ComfyUI not reachable via $act; see journalctl -u comfyui.service" >&2
              exit 1
            fi
          fi
          ${sleep} 2 & wait $!
        done
      '';

  hold = pkgs.writeShellApplication {
    name = "comfyui-hold";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      # Keep ComfyUI running outside llama-swap's control for a long render:
      # pause llama-swap (unloads every model and rejects requests, including
      # /comfyui/), start ComfyUI directly, resume llama-swap on exit.
      # Use ComfyUI directly at ${comfyUrl}/ while held.
      ls=''${LLAMA_SWAP_URL:-${llamaSwapUrl}}
      curl -fsS -X POST "$ls/api/models/pause" >/dev/null
      echo "llama-swap paused; starting ComfyUI at ${comfyUrl}/ (Ctrl-C to release)"
      resume() { curl -fsS -X POST "$ls/api/models/resume" >/dev/null && echo "llama-swap resumed"; }
      trap resume EXIT
      ${shim { }}
    '';
    meta.license = lib.licenses.gpl3Plus;
  };

  modelType = types.submodule {
    options = {
      path = mkOption {
        type = types.str;
        description = "Path relative to modelsDir.";
      };
      url = mkOption { type = types.str; };
      sha256 = mkOption {
        type = types.str;
        description = "Hex sha256.";
      };
      size = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
      };
      license = mkOption {
        type = types.str;
        default = "unknown";
      };
      source = mkOption {
        type = types.str;
        default = "";
      };
    };
  };
in
{
  options.services.comfyui-strix = {
    enable = mkEnableOption "ComfyUI (ROCm, gfx1151) as an on-demand service";

    user = mkOption {
      type = types.str;
      example = "alice";
      description = "Existing user the service runs as. Owns stateDir and modelsDir.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/data/comfyui";
      description = ''
        Mutable state: user/ (settings and saved workflows under
        user/default/workflows), input/, output/, temp/, custom_nodes/ (ad hoc
        nodes) and cache/ (MIOpen, Triton, Hugging Face). Created by tmpfiles.
      '';
    };

    modelsDir = mkOption {
      type = types.str;
      default = "/data/models/comfyui";
      description = "Model tree passed as --models-directory. Created by tmpfiles.";
    };

    port = mkOption {
      type = types.port;
      default = 8188;
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [
        "--disable-mmap"
        "--bf16-vae"
        "--highvram"
        "--disable-partner-nodes"
      ];
      description = "ComfyUI command-line flags. Replaces the defaults when set.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        MIOPEN_FIND_MODE = "FAST";
      };
      description = ''
        Extra environment. The launcher already sets MIOPEN_SEARCH_CUTOFF=1 and
        points MIOPEN_USER_DB_PATH, MIOPEN_CUSTOM_CACHE_DIR, TRITON_CACHE_DIR,
        TORCHINDUCTOR_CACHE_DIR, HF_HOME and XDG_CACHE_HOME into stateDir;
        values given here win.
      '';
    };

    customNodes = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Curated custom nodes built with `lib.mkCustomNode`; loaded from the store.";
    };

    extraPythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "ps: [ ]";
      description = "Extra Python packages for ad hoc nodes in stateDir/custom_nodes (no runtime pip).";
    };

    models = mkOption {
      type = types.listOf modelType;
      default = (import ./models.nix).smoke;
      defaultText = lib.literalMD "the FLUX.2 klein 4B smoke-test set (~16.1 GB)";
      description = ''
        Declared models, checked before every start (missing ones fail the
        start with the fetch command). Nothing is downloaded automatically.
        May be `[ ]`.
      '';
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = launcher;
      description = "The launcher built from these options.";
    };

    internal = mkOption {
      type = types.attrsOf types.package;
      internal = true;
      readOnly = true;
      default = {
        shim = shim { };
        inherit hold;
      };
      description = "Generated scripts, exposed for tests.";
    };

    llamaSwap = {
      enable = mkEnableOption "on-demand start/stop and GPU arbitration through llama-swap (model id comfyui_auto, route /comfyui/)";

      mode = mkOption {
        type = types.enum [
          "polkit"
          "socket"
        ];
        default = "polkit";
        description = ''
          How llama-swap's shim controls comfyui.service.
          polkit: `systemctl start/stop` over D-Bus, allowed by a polkit rule
          scoped to this one unit. socket: no D-Bus; a socket-activated
          systemd-socket-proxyd starts comfyui.service on connection and it
          stops shortly after the shim's keepalive ends.
        '';
      };

      ttl = mkOption {
        type = types.ints.unsigned;
        default = 1800;
        description = "Idle seconds before llama-swap stops ComfyUI (0 = never). WebSocket traffic does not count as activity.";
      };

      unloadTimeout = mkOption {
        type = types.ints.positive;
        default = 30;
      };

      matrixVar = mkOption {
        type = types.str;
        default = "comfy";
        description = "Name for comfyui_auto in the llama-swap matrix `vars`.";
      };

      sets = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          image = "gemma4 & comfy";
        };
        description = ''
          Matrix sets to add (merged with the host's). Empty: no matrix entries
          are added and ComfyUI only runs alone (or under the host's own rules).
        '';
      };

      evictCost = mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      socketPort = mkOption {
        type = types.port;
        default = 8189;
        description = "Activation socket (socket mode only).";
      };

      socketIdleSeconds = mkOption {
        type = types.ints.positive;
        default = 5;
      };
    };

    expose = {
      enable = mkEnableOption "an nginx vhost publishing only llama-swap's /comfyui/ route";

      port = mkOption {
        type = types.port;
        default = 8190;
      };

      interfaces = mkOption {
        type = types.listOf types.str;
        default = [ "tailscale0" ];
        example = [
          "enp1s0"
          "tailscale0"
        ];
        description = "Interfaces whose firewall opens `port` (with openFirewall).";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.expose.enable -> cfg.llamaSwap.enable;
          message = "services.comfyui-strix.expose requires llamaSwap.enable (it publishes llama-swap's /comfyui/ route).";
        }
        {
          assertion = cfg.llamaSwap.enable -> ls.enable;
          message = "services.comfyui-strix.llamaSwap.enable requires services.llama-swap.enable.";
        }
      ];

      systemd.tmpfiles.settings."10-comfyui-strix" = {
        ${cfg.stateDir}.d = {
          inherit (cfg) user;
          group = config.users.users.${cfg.user}.group;
          mode = "0750";
        };
        ${cfg.modelsDir}.d = {
          inherit (cfg) user;
          group = config.users.users.${cfg.user}.group;
          mode = "0755";
        };
      };

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "comfyui-models" ''
          export COMFYUI_MODELS_MANIFEST="''${COMFYUI_MODELS_MANIFEST:-${manifestFile}}"
          export COMFYUI_MODELS_DIR="''${COMFYUI_MODELS_DIR:-${cfg.modelsDir}}"
          exec ${lib.getExe strix.comfyui-models} "$@"
        '')
        strix.run-workflow
      ];

      systemd.services.comfyui = {
        description = "ComfyUI (nix-comfyui-strix)";
        after = [ "network.target" ];
        # Not wantedBy anything: started on demand (llama-swap, comfyui-hold,
        # or `systemctl start comfyui`).
        environment = {
          HOME = cfg.stateDir;
          COMFYUI_MODELS_MANIFEST = "${manifestFile}";
          # extraArgs is the complete flag list: disable the launcher's defaults.
          COMFYUI_ARGS = "";
        }
        // cfg.environment;
        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = config.users.users.${cfg.user}.group;
          SupplementaryGroups = [
            "render"
            "video"
          ];
          ExecStartPre = "${lib.getExe strix.comfyui-models} check --models-dir ${lib.escapeShellArg cfg.modelsDir}";
          ExecStart = lib.escapeShellArgs (
            [
              (lib.getExe launcher)
              "--skip-model-check"
              "--state-dir"
              cfg.stateDir
              "--models-dir"
              cfg.modelsDir
              "--listen"
              cfg.listenAddress
              "--port"
              (toString cfg.port)
              "--"
            ]
            ++ cfg.extraArgs
          );
          ExecStartPost = "${waitReady}";
          TimeoutStartSec = 600;
          TimeoutStopSec = 60;
          Restart = "no";
          WorkingDirectory = cfg.stateDir;

          # Sandbox. ComfyUI has no authentication and custom nodes run
          # arbitrary code, so the process sees only its state and models.
          # MemoryDenyWriteExecute is deliberately absent (ROCm/Triton JIT).
          ProtectHome = "tmpfs";
          ProtectSystem = "strict";
          ReadWritePaths = [
            cfg.stateDir
            cfg.modelsDir
          ];
          PrivateTmp = true;
          PrivateDevices = false; # /dev/kfd, /dev/dri
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
        };
      };
    }

    (mkIf cfg.llamaSwap.enable (mkMerge [
      {
        services.llama-swap.settings = {
          models.comfyui_auto = {
            cmd = "${shim { }}";
            proxy = comfyUrl;
            checkEndpoint = "/";
            ttl = cfg.llamaSwap.ttl;
            unloadTimeout = cfg.llamaSwap.unloadTimeout;
            unlisted = true;
          }
          // lib.optionalAttrs (cfg.llamaSwap.mode == "polkit") {
            cmdStop = "${systemctl} --no-ask-password stop ${unit}";
          };
          matrix = mkIf (cfg.llamaSwap.sets != { }) {
            vars.${cfg.llamaSwap.matrixVar} = "comfyui_auto";
            sets = cfg.llamaSwap.sets;
            evict_costs = mkIf (cfg.llamaSwap.evictCost != null) {
              ${cfg.llamaSwap.matrixVar} = cfg.llamaSwap.evictCost;
            };
          };
        };

        environment.systemPackages = [ hold ];

        # llama-swap's DynamicUser (and the owner, for comfyui-hold) may
        # start/stop/restart exactly this unit.
        security.polkit.enable = true;
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                action.lookup("unit") == "${unit}" &&
                (subject.user == "llama-swap" || subject.user == "${cfg.user}")) {
              var verb = action.lookup("verb");
              if (verb == "start" || verb == "stop" || verb == "restart") {
                return polkit.Result.YES;
              }
            }
          });
        '';
      }

      (mkIf (cfg.llamaSwap.mode == "socket") {
        systemd.services.comfyui.unitConfig.StopWhenUnneeded = true;

        systemd.sockets.comfyui-activate = {
          description = "ComfyUI activation socket (nix-comfyui-strix)";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString cfg.llamaSwap.socketPort}" ];
        };
        systemd.services.comfyui-activate = {
          description = "ComfyUI activation proxy (nix-comfyui-strix)";
          requires = [ "comfyui.service" ];
          after = [ "comfyui.service" ];
          serviceConfig = {
            ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${toString cfg.llamaSwap.socketIdleSeconds}s ${probeHost}:${toString cfg.port}";
            DynamicUser = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            NoNewPrivileges = true;
          };
        };
      })
    ]))

    (mkIf cfg.expose.enable {
      services.nginx = {
        enable = true;
        recommendedProxySettings = lib.mkDefault true;
        virtualHosts.comfyui-strix = {
          listen = [
            {
              addr = "0.0.0.0";
              inherit (cfg.expose) port;
            }
            {
              addr = "[::]";
              inherit (cfg.expose) port;
            }
          ];
          # Only llama-swap's /comfyui/ route is reachable through this vhost:
          # every path is mapped under it, so no LLM endpoint is exposed.
          # A plain GET of the page starts a stopped ComfyUI (llama-swap v268:
          # only static assets, /ws and /api/jobs are ignored), so no extra
          # "start" page is needed.
          # $request_uri (not a URI part in proxy_pass) keeps the request path
          # undecoded: the web app saves workflows to
          # /api/userdata/workflows%2F<name>.json, which a normalised path breaks.
          locations."/" = {
            proxyPass = "${llamaSwapUrl}/comfyui$request_uri";
            proxyWebsockets = true;
            extraConfig = ''
              client_max_body_size 512m;
              proxy_read_timeout 1h;
              proxy_send_timeout 1h;
              proxy_buffering off;
            '';
          };
        };
      };
      networking.firewall.interfaces = mkIf cfg.expose.openFirewall (
        lib.genAttrs cfg.expose.interfaces (_: {
          allowedTCPPorts = [ cfg.expose.port ];
        })
      );
    })
  ]);
}
