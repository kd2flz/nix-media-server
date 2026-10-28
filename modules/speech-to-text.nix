
{ lib, config, pkgs, ... }:

let
  cfg = config.services.speechToText;
  mediaCfg = config.services.mediaServer or {};

  ########################################
  # Built-in ggml model table
  #
  # Hashes are the flat sha256 of the files published in the whisper.cpp
  # Hugging Face repository (the form `pkgs.fetchurl` verifies). Only
  # models listed here can be selected by name; anything else must be
  # supplied through `modelFile`.
  ########################################
  models = {
    "small.en" = {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin";
      hash = "sha256-xhONbVjsyDIgl+D5h8MvG+i7ChhTKj+I9zTRu/nEHl0=";
    };
  };

  modelFile =
    if cfg.modelFile != null then cfg.modelFile
    else pkgs.fetchurl models.${cfg.model};

  domainBase = mediaCfg.domainBase or "localhost";

  tlsLine =
    if (mediaCfg.tls.certFile or null) != null && (mediaCfg.tls.keyFile or null) != null
    then "tls ${mediaCfg.tls.certFile} ${mediaCfg.tls.keyFile}"
    else "tls internal";

  # When the hash comes from a file, Caddy reads it from the environment at
  # adapt time; `{$VAR}` is substituted while the Caddyfile is parsed.
  basicAuthHash =
    if cfg.basicAuth.hashFile != null
    then "{$SPEECH_TO_TEXT_BASIC_AUTH_HASH}"
    else cfg.basicAuth.hash;

  basicAuthFromFile = cfg.expose == "public" && cfg.basicAuth.hashFile != null;

  # whisper-server ships a tiny inline web UI on / and the OpenAI-style
  # multipart endpoint on /inference. Neither requires a build step, so the
  # module only needs a model file and a systemd unit.
  serverArgs =
    [
      "-m" "${modelFile}"
      "--host" cfg.host
      "--port" (toString cfg.port)
      "--threads" (toString cfg.threads)
      "--language" cfg.language
      "--tmp-dir" "/var/lib/speech-to-text/tmp"
    ]
    ++ lib.optional cfg.convert "--convert"
    ++ lib.optionals (cfg.requestPath != "") [ "--request-path" cfg.requestPath ]
    ++ lib.optionals (cfg.inferencePath != "/inference") [ "--inference-path" cfg.inferencePath ];
in
{
  ########################################
  # Module options
  ########################################
  options.services.speechToText = {
    enable = lib.mkEnableOption "Speech-to-text transcription server (whisper.cpp)";

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the transcription server listens on. Keep on loopback when exposing through Caddy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the transcription server listens on.";
    };

    expose = lib.mkOption {
      type = lib.types.enum [ "public" "private" ];
      default = "public";
      description = ''
        "public" reverse-proxies the service through Caddy at
        speech.<services.mediaServer.domainBase>. "private" keeps the service
        on loopback with no vhost and no reverse proxy.
      '';
    };

    basicAuth = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "User name for Caddy basic auth. Requires `hash` or `hashFile` to be set.";
      };

      hash = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          bcrypt hash of the basic auth password, e.g.
          `htpasswd -nBC 10 "" | tr -d ':\n'`. The hash is stored in the Nix
          store and in the generated Caddyfile — never put a plaintext
          password here. Prefer `hashFile` for a hash kept in sops.
        '';
      };

      hashFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the bcrypt hash (typically a sops-nix
          secret). Read at activation into an environment file consumed by
          Caddy, so the hash never enters the Nix store. Overrides `hash`.
        '';
      };
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "small.en";
      description = "Name of a ggml model from the module's built-in table.";
    };

    modelFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Explicit path to a ggml model file. Overrides `model`.";
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "en";
      description = "Spoken language passed to whisper-server. Use \"auto\" to detect per request.";
    };

    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "CPU threads used for inference.";
    };

    convert = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Let the server shell out to ffmpeg so any audio/video container is
        accepted. Requires a `package` built with ffmpeg support.
      '';
    };

    requestPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Extra path prefix mounted in front of the inference route. Setting
        "/v1/audio" together with `inferencePath` = "/transcriptions" yields an
        OpenAI-compatible endpoint.
      '';
    };

    inferencePath = lib.mkOption {
      type = lib.types.str;
      default = "/inference";
      description = "Route that accepts the multipart transcription request.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.whisper-cpp.override { withFFmpegSupport = true; };
      defaultText = lib.literalExpression "pkgs.whisper-cpp.override { withFFmpegSupport = true; }";
      description = "whisper.cpp package. The default build includes ffmpeg support so the server can transcode arbitrary media.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the firewall port for direct access. Not needed when exposing through Caddy.";
    };
  };


  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.modelFile != null || builtins.hasAttr cfg.model models;
        message = "services.speechToText.model = \"${cfg.model}\" is not in the built-in table. Use services.speechToText.modelFile to point at a ggml model file.";
      }
      {
        assertion = cfg.expose != "public" || mediaCfg.enable or false;
        message = "services.speechToText.expose = \"public\" requires services.mediaServer.enable = true because Caddy is configured by the media-server module.";
      }
      {
        assertion = (cfg.basicAuth.user == "") == (cfg.basicAuth.hash == "" && cfg.basicAuth.hashFile == null);
        message = "services.speechToText.basicAuth.user must be set together with basicAuth.hash or basicAuth.hashFile.";
      }
      {
        assertion = !(cfg.basicAuth.hash != "" && cfg.basicAuth.hashFile != null);
        message = "services.speechToText.basicAuth.hash and basicAuth.hashFile are mutually exclusive; set only one.";
      }
      {
        assertion = !basicAuthFromFile || cfg.basicAuth.user != "";
        message = "services.speechToText.basicAuth.hashFile requires basicAuth.user to be set.";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    users.groups.speech-to-text = { };
    users.users.speech-to-text = {
      isSystemUser = true;
      group = "speech-to-text";
      description = "Speech-to-text transcription service";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/speech-to-text 0750 speech-to-text speech-to-text - -"
      "d /var/lib/speech-to-text/tmp 0700 speech-to-text speech-to-text - -"
    ];

    systemd.services.speech-to-text = {
      description = "speech-to-text: whisper.cpp transcription server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "speech-to-text";
        Group = "speech-to-text";
        WorkingDirectory = "/var/lib/speech-to-text";
        ExecStart = "${cfg.package}/bin/whisper-server ${lib.concatStringsSep " " serverArgs}";
        Restart = "on-failure";
        RestartSec = "5s";

        # The server is unauthenticated and shells out to ffmpeg, so it only
        # ever binds loopback and never gets privileges beyond its own user.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        # @resources is deliberately left alone: it contains sched_setaffinity,
        # which glibc calls from every pthread_create.
        SystemCallFilter = [ "~@privileged" "~@obsolete" ];
        CapabilityBoundingSet = "";
        ReadWritePaths = [ "/var/lib/speech-to-text" ];
      };
    };

    # Reverse proxy through Caddy. `services.caddy.virtualHosts` is rendered
    # after `services.caddy.extraConfig`, so it coexists with the vhosts the
    # media-server module writes there.
    services.caddy.virtualHosts = lib.mkIf (cfg.expose == "public") {
      "speech.${domainBase}" = {
        extraConfig = ''
          ${tlsLine}
          reverse_proxy ${cfg.host}:${toString cfg.port}
          ${lib.optionalString (cfg.basicAuth.user != "") ''
            basic_auth {
              ${cfg.basicAuth.user} ${basicAuthHash}
            }
          ''}
        '';
      };
    };

    # Render the bcrypt hash into a root-owned, caddy-readable environment
    # file. The file lives under /run, so the hash never touches the Nix
    # store or /etc. The host should set `restartUnits` on the source secret
    # so rotating it restarts this unit and Caddy.
    systemd.services.speech-to-text-auth-env = lib.mkIf basicAuthFromFile {
      description = "speech-to-text: render Caddy basic-auth hash";
      wantedBy = [ "multi-user.target" ];
      before = [ "caddy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "speech-to-text-auth-env" ''
          install -d -m 0755 /run/speech-to-text
          printf 'SPEECH_TO_TEXT_BASIC_AUTH_HASH=%s\n' \
            "$(cat ${lib.escapeShellArg (toString cfg.basicAuth.hashFile)})" \
            > /run/speech-to-text/caddy.env
          chown root:caddy /run/speech-to-text/caddy.env
          chmod 0400 /run/speech-to-text/caddy.env
        '';
      };
    };

    services.caddy.environmentFile =
      lib.mkIf basicAuthFromFile "/run/speech-to-text/caddy.env";

    networking.firewall.allowedTCPPorts =
      lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
