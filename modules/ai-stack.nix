{ lib, config, pkgs, ... }:

let
  cfg = config.services.aiStack;
  mediaCfg = config.services.mediaServer;
  ollamaCfg = config.services.ollamaServer;
  sttCfg = config.services.speechToText;

  hasMediaServer = mediaCfg.enable or false;
  defaultDomain = if hasMediaServer then "ai.${mediaCfg.domainBase}" else "ai.localhost";

  tlsLine =
    if hasMediaServer
    then
      if mediaCfg.tls.certFile != null && mediaCfg.tls.keyFile != null
      then "tls ${mediaCfg.tls.certFile} ${mediaCfg.tls.keyFile}"
      else "tls internal"
    else "tls internal";
in
{
  ########################################
  # Module options
  ########################################
  options.services.aiStack = {
    enable = lib.mkEnableOption "Open WebUI as a unified frontend for local AI backends (Ollama, whisper.cpp)";

    domainBase = lib.mkOption {
      type = lib.types.str;
      default = defaultDomain;
      defaultText = lib.literalExpression ''if config.services.mediaServer.enable then "ai.${config.services.mediaServer.domainBase}" else "ai.localhost"'';
      description = "FQDN to expose Open WebUI on (e.g. ai.media-bel.ccistack.com).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Loopback address for Open WebUI.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Loopback port for Open WebUI.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/open-webui/open-webui:latest";
      description = "OCI image to run for Open WebUI.";
    };

    enableSignup = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow user registration in Open WebUI. Disable after creating the initial admin account.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the Open WebUI port to the LAN (only needed if you don't go through Caddy).";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/open-webui";
      description = "Persistent data directory for Open WebUI.";
    };
  };

  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = ollamaCfg.enable or sttCfg.enable;
        message = "services.aiStack.enable requires at least one backend enabled (services.ollamaServer.enable or services.speechToText.enable).";
      }
    ];

    ########################################
    # Directories
    ########################################
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 root root - -"
    ];

    ########################################
    # Open WebUI container
    ########################################
    virtualisation.oci-containers.containers.open-webui = {
      image = cfg.image;
      autoStart = true;

      volumes = [
        "${cfg.dataDir}:/app/backend/data"
      ];

      environment =
        {
          WEBUI_URL = "https://${cfg.domainBase}";
          ENABLE_SIGNUP = if cfg.enableSignup then "true" else "false";
          HOST = cfg.host;
          PORT = toString cfg.port;
        }
        // lib.optionalAttrs (ollamaCfg.enable or false) {
          OLLAMA_BASE_URL = "http://${ollamaCfg.host}:${toString ollamaCfg.port}";
        }
        // lib.optionalAttrs (sttCfg.enable or false) {
          AUDIO_STT_ENGINE = "openai";
          AUDIO_STT_OPENAI_API_BASE_URL = "http://${sttCfg.host}:${toString sttCfg.port}/v1";
          AUDIO_STT_OPENAI_API_KEY = "openwebui-local";
          AUDIO_STT_MODEL = "whisper-1";
        };

      extraOptions = [
        "--name=open-webui"
        "--network=host"
      ];
    };

    ########################################
    # Caddy reverse proxy
    ########################################
    services.caddy.virtualHosts = lib.mkIf hasMediaServer {
      "${cfg.domainBase}" = {
        extraConfig = ''
          ${tlsLine}
          reverse_proxy ${cfg.host}:${toString cfg.port}
        '';
      };
    };

    ########################################
    # Firewall
    ########################################
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
