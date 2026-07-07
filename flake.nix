{
  description = "KbaseBot — personal knowledge-base assistant (Telegram + Claude, Elixir)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    (flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        beamPkgs = pkgs.beam.packages.erlang_27;
        elixir = beamPkgs.elixir_1_17;
      in {
        # Nix-built OTP release. Runs anywhere Nix runs (Linux, macOS,
        # NixOS): `nix run github:PsicoThePato/kbase-bot -- start` with the
        # environment (.env) exported. Mutable state must live OUTSIDE the
        # store — set DB_PATH and REPO_PATH (the service modules under
        # ./nix do this for you).
        packages.kbase-bot = beamPkgs.mixRelease {
          inherit elixir;
          pname = "kbase_bot";
          version = "0.1.0";
          src = ./.;

          mixFodDeps = beamPkgs.fetchMixDeps {
            inherit elixir;
            pname = "kbase_bot-deps";
            version = "0.1.0";
            src = ./.;
            # Recompute after any mix.lock change:
            #   nix build .#kbase-bot.mixFodDeps  (read the "got:" hash from the error)
            hash = "sha256-TN93W4qJEGavvQnZDHywmhwk+FcyOx0UPB/GFjbTyLo=";
          };

          nativeBuildInputs = [ pkgs.gcc pkgs.pkg-config pkgs.makeWrapper ];
          buildInputs = [ pkgs.sqlite ];

          # exqlite (0.36) defaults to a cc_precompiler path that downloads a
          # prebuilt NIF at build time (offline sandbox → fails). Setting
          # EXQLITE_USE_SYSTEM disables the precompiler so it compiles the NIF
          # against the SQLite in buildInputs — hermetic, no download.
          EXQLITE_USE_SYSTEM = "1";
        };

        packages.default = self.packages.${system}.kbase-bot;

        # `nix run . -- start` / `nix run . -- remote` / `nix run . -- eval …`
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.kbase-bot}/bin/kbase_bot";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            elixir_1_17
            erlang_27
            sqlite
            gcc
            pkg-config
            nodejs_22 # for the optional @tobilu/qmd semantic-search CLI
          ];

          shellHook = ''
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"
            export ERL_AFLAGS="-kernel shell_history enabled"
            mkdir -p "$MIX_HOME" "$HEX_HOME"
            export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$PWD/node_modules/.bin:$PATH"
          '';
        };
      }))
    // {
      # System service (dedicated user, hardened) — for a NixOS machine:
      #   imports = [ inputs.kbase-bot.nixosModules.default ];
      #   services.kbase-bot = { enable = true; environmentFile = …; };
      nixosModules.kbase-bot = import ./nix/nixos-module.nix self;
      nixosModules.default = self.nixosModules.kbase-bot;

      # User service — systemd user unit on Linux, launchd agent on macOS.
      # For home-manager on a MacBook or any Linux box:
      #   imports = [ inputs.kbase-bot.homeModules.default ];
      #   services.kbase-bot = { enable = true; environmentFile = …; };
      homeModules.kbase-bot = import ./nix/home-module.nix self;
      homeModules.default = self.homeModules.kbase-bot;
    };
}
