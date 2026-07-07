# NixOS module for the KbaseBot Telegram assistant.
#
# Import via the flake:  imports = [ inputs.kbase-bot.nixosModules.default ];
# then set:              services.kbase-bot.enable = true;
#                        services.kbase-bot.environmentFile = "/run/secrets/kbase-bot.env";
#
# The service runs the Nix-built release as a dedicated system user. Mutable
# state (the knowledge base, SQLite db, tzdata cache) lives in StateDirectory —
# the Nix store is read-only, so nothing the bot writes may live in the package.
#
# The knowledge base itself is content, not code: put the decrypted markdown
# at <stateDir>/knowledge_base (or point REPO_PATH elsewhere via
# extraEnvironment) — e.g. clone the personal repo and run scripts/decrypt.sh
# as the service user.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.kbase-bot;
in
{
  options.services.kbase-bot = {
    enable = lib.mkEnableOption "KbaseBot personal Telegram assistant";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.kbase-bot;
      defaultText = lib.literalExpression "kbase-bot flake package";
      description = "The kbase_bot release package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "kbase-bot";
      description = "System user the service runs as.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kbase-bot";
      description = "Writable working directory (knowledge base, SQLite db, tzdata cache).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to an EnvironmentFile holding the bot's secrets — kept OUT of the
        Nix store (store is world-readable). Must define at least:
        TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ANTHROPIC_API_KEY. Optional:
        MODEL, VOYAGE_API_KEY, TODOIST_API_KEY, EXA_API_KEY, GIPHY_API_KEY,
        AUTO_COMMIT, FEDERATION_* (see docs/multiplayer-federation.md).
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { FEDERATION_ENABLED = "true"; TIMEZONE = "America/Sao_Paulo"; };
      description = "Extra (non-secret) environment variables for the service.";
    };

    qmdEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable QMD semantic search (requires the qmd CLI on PATH; off by default on NixOS).";
    };

    federationPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 4040;
      description = ''
        Federation HTTP inbound port. Setting this exports FEDERATION_PORT;
        combine with FEDERATION_ENABLED=true (via extraEnvironment or the
        environment file) and openFirewall to accept peer traffic.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open federationPort in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.openFirewall -> cfg.federationPort != null;
        message = "services.kbase-bot.openFirewall requires federationPort to be set.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.stateDir;
      description = "KbaseBot service user";
    };
    users.groups.${cfg.user} = { };

    networking.firewall.allowedTCPPorts =
      lib.optional (cfg.openFirewall && cfg.federationPort != null) cfg.federationPort;

    systemd.services.kbase-bot = {
      description = "KbaseBot Telegram Bot";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # git is needed for the bot's auto-commit of the knowledge base.
      path = [ pkgs.git ];

      environment = {
        LANG = "C.UTF-8";
        REPO_PATH = "${cfg.stateDir}/knowledge_base";
        # The release lives in the read-only store — all writes go to state.
        DB_PATH = "${cfg.stateDir}/repo.db";
        QMD_ENABLED = lib.boolToString cfg.qmdEnabled;
        # tzdata must write its release cache somewhere writable, not the store.
        TZDATA_DIR = "${cfg.stateDir}/tzdata";
        RELEASE_TMP = "${cfg.stateDir}/tmp";
        HOME = cfg.stateDir;
        # The Nix build strips the release cookie (store is world-readable);
        # the bot never clusters, so disable distribution and pin a dummy.
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "kbase-bot-no-dist";
      } // lib.optionalAttrs (cfg.federationPort != null) {
        FEDERATION_PORT = toString cfg.federationPort;
      } // cfg.extraEnvironment;

      preStart = "mkdir -p ${cfg.stateDir}/tzdata ${cfg.stateDir}/tmp";

      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = cfg.stateDir;
        StateDirectory = "kbase-bot";
        StateDirectoryMode = "0750";
        EnvironmentFile = cfg.environmentFile;
        ExecStart = "${cfg.package}/bin/kbase_bot start";
        Restart = "always";
        RestartSec = 5;

        # Hardening — the bot only needs its own state dir.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };
  };
}
