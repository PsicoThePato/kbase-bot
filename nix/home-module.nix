# Home Manager module for the KbaseBot Telegram assistant — the per-user
# counterpart of nix/nixos-module.nix, for machines that aren't NixOS:
# a systemd *user* service on Linux, a launchd agent on macOS.
#
#   imports = [ inputs.kbase-bot.homeModules.default ];
#   services.kbase-bot = {
#     enable = true;
#     environmentFile = "/Users/me/.config/kbase-bot/secrets.env";
#   };
#
# Both platforms run the same wrapper: it creates the state dirs, sources the
# environment file (launchd has no EnvironmentFile concept), and execs the
# release. State defaults to ~/.local/share/kbase-bot; the knowledge base is
# content, not code — put the decrypted markdown at <stateDir>/knowledge_base
# or point repoPath at your existing checkout.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.kbase-bot;

  stateDir = "${config.xdg.dataHome}/kbase-bot";

  wrapper = pkgs.writeShellScript "kbase-bot-start" ''
    set -euo pipefail
    mkdir -p ${lib.escapeShellArg cfg.stateDir}/tzdata ${lib.escapeShellArg cfg.stateDir}/tmp

    export LANG=C.UTF-8
    # The Nix build strips the release cookie (store is world-readable);
    # the bot never clusters, so disable distribution and pin a dummy.
    export RELEASE_DISTRIBUTION=none
    export RELEASE_COOKIE=kbase-bot-no-dist
    export REPO_PATH=${lib.escapeShellArg cfg.repoPath}
    export DB_PATH=${lib.escapeShellArg "${cfg.stateDir}/repo.db"}
    export QMD_ENABLED=${lib.boolToString cfg.qmdEnabled}
    export TZDATA_DIR=${lib.escapeShellArg "${cfg.stateDir}/tzdata"}
    export RELEASE_TMP=${lib.escapeShellArg "${cfg.stateDir}/tmp"}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (name: value: "export ${name}=${lib.escapeShellArg value}") cfg.extraEnvironment)}

    # git for knowledge-base auto-commit.
    export PATH=${lib.makeBinPath [ pkgs.git ]}:"$PATH"

    set -a
    . ${lib.escapeShellArg cfg.environmentFile}
    set +a

    exec ${cfg.package}/bin/kbase_bot start
  '';
in
{
  options.services.kbase-bot = {
    enable = lib.mkEnableOption "KbaseBot personal Telegram assistant (user service)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.kbase-bot;
      defaultText = lib.literalExpression "kbase-bot flake package";
      description = "The kbase_bot release package to run.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to a file of KEY=value lines holding the bot's secrets
        (kept out of the Nix store). Must define at least TELEGRAM_BOT_TOKEN,
        TELEGRAM_CHAT_ID, ANTHROPIC_API_KEY.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = stateDir;
      defaultText = lib.literalExpression ''"''${config.xdg.dataHome}/kbase-bot"'';
      description = "Writable directory for the SQLite db, tzdata cache and tmp.";
    };

    repoPath = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/knowledge_base";
      defaultText = lib.literalExpression ''"''${config.xdg.dataHome}/kbase-bot/knowledge_base"'';
      description = "The (decrypted) knowledge-base directory the bot reads and writes.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { TIMEZONE = "America/Sao_Paulo"; QMD_PATH = "qmd"; };
      description = "Extra (non-secret) environment variables for the service.";
    };

    qmdEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable QMD semantic search (requires the qmd CLI on PATH).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Linux (non-NixOS included): systemd user unit. Survives logout only if
    # lingering is on: loginctl enable-linger $USER.
    systemd.user.services.kbase-bot = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      Unit = {
        Description = "KbaseBot Telegram Bot";
        After = [ "network-online.target" ];
      };

      Service = {
        ExecStart = "${wrapper}";
        Restart = "always";
        RestartSec = 5;
      };

      Install.WantedBy = [ "default.target" ];
    };

    # macOS: launchd agent (starts at login, restarts on crash).
    launchd.agents.kbase-bot = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      enable = true;

      config = {
        Label = "com.kbase-bot.agent";
        ProgramArguments = [ "${wrapper}" ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 5;
        StandardOutPath = "${cfg.stateDir}/kbase-bot.log";
        StandardErrorPath = "${cfg.stateDir}/kbase-bot.log";
      };
    };
  };
}
