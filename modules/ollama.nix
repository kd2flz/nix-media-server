
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
  };


  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {

    services.ollama = {
      enable = true;
      host = cfg.host;
      port = cfg.port;
      loadModels = cfg.models;
      acceleration = cfg.acceleration;
    };

    networking.firewall.allowedTCPPorts =
      lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
