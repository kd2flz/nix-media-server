
{ lib, config, pkgs, ... }:

let
  cfg = config.services.ollamaServer;
in
{
  ########################################
  # Module options
  ########################################
  options.services.ollamaServer = {
    enable = lib.mkEnableOption "Ollama LLM inference server";

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address Ollama listens on. Defaults to all interfaces.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 11434;
      description = "Port Ollama listens on.";
    };

    models = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "phi4-mini" ];
      description = ''
        List of model names to pull and keep available on startup.
        Names must match those accepted by `ollama pull`.
      '';
    };

    acceleration = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "cuda" "rocm" ]);
      default = null;
      description = ''
        GPU acceleration backend. null = CPU-only.
        "cuda"  → NVIDIA CUDA (requires hardware.nvidia to be configured).
        "rocm"  → AMD ROCm.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the firewall port for Ollama.";
    };

    contextLength = lib.mkOption {
      type = lib.types.int;
      default = 131072;
      description = ''
        Default context window in tokens. Sets OLLAMA_CONTEXT_LENGTH.
        phi4-mini supports 128K natively; this default gives headroom.
        Lower if VRAM is constrained (e.g. 65536 for 8 GB GPU).
      '';
    };
  };


  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {

    # The nixpkgs ollama package runs a large Go test suite during build which
    # exhausts RAM and time on modest hardware. Override to skip checks — the
    # binary is still compiled in full; only the test runner is suppressed.
    nixpkgs.overlays = [
      (final: prev: {
        ollama = prev.ollama.overrideAttrs (_: { doCheck = false; });
        ollama-cuda = prev.ollama-cuda.overrideAttrs (_: { doCheck = false; });
        ollama-rocm = prev.ollama-rocm.overrideAttrs (_: { doCheck = false; });
      })
    ];

    services.ollama = {
      enable = true;
      host = cfg.host;
      port = cfg.port;
      loadModels = cfg.models;
      acceleration = cfg.acceleration;
    };

    systemd.services.ollama.environment.OLLAMA_CONTEXT_LENGTH =
      toString cfg.contextLength;

    networking.firewall.allowedTCPPorts =
      lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
