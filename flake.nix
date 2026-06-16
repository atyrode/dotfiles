{
  description = "atyrode dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
  let
    lib = nixpkgs.lib;

    defaultUsername = "alex";

    overlays = [
      (final: prev: {
        codex = prev.codex.overrideAttrs (_finalAttrs: previousAttrs: {
          version = "0.139.0";
          src = prev.fetchFromGitHub {
            owner = "openai";
            repo = "codex";
            tag = "rust-v0.139.0";
            hash = "sha256-XjzlkBUkBey+P3tFLDYB3ae5oseUfW5tmzhLzqlqj2E=";
          };
          cargoHash = "sha256-8mN4OTRJvt2mBYHQXZS55PSOChLqEIiXwPu2y+2MZ9o=";
          postPatch = ''
            substituteInPlace $cargoDepsCopy/*/webrtc-sys-*/build.rs \
              --replace-fail "cargo:rustc-link-lib=static=webrtc" "cargo:rustc-link-lib=dylib=webrtc"
            substituteInPlace Cargo.toml \
              --replace-fail 'lto = "thin"' "" \
              --replace-fail 'codegen-units = 1' ""
          '';
          nativeBuildInputs =
            previousAttrs.nativeBuildInputs
            ++ final.lib.optionals final.stdenv.hostPlatform.isDarwin [
              final.lld
            ];
          env =
            previousAttrs.env
            // final.lib.optionalAttrs final.stdenv.hostPlatform.isDarwin {
              NIX_CFLAGS_LINK = "-fuse-ld=${final.lib.getExe' final.lld "ld64.lld"}";
            };
        });
      })
    ];

    systems = [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    defaultSystem = "aarch64-darwin";

    forAllSystems = lib.genAttrs systems;

    homeDirectoryFor = system: username:
      if lib.hasSuffix "-darwin" system
      then "/Users/${username}"
      else "/home/${username}";

    # Helper function to create home configuration
    mkHomeConfig = { system, username ? defaultUsername, homeDirectory ? homeDirectoryFor system username }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
        };

        modules = [
          ./home
          {
            home.username = username;
            home.homeDirectory = homeDirectory;
          }
        ];
      };

    configs = forAllSystems (system: mkHomeConfig { inherit system; });
  in {
    homeConfigurations =
      {
        # Default configuration for this Mac.
        ${defaultUsername} = configs.${defaultSystem};
      }
      // lib.mapAttrs' (
        system: config:
          lib.nameValuePair "${defaultUsername}-${system}" config
      ) configs
      // {
        "${defaultUsername}-darwin" = configs.${defaultSystem};
        "${defaultUsername}-linux" = configs."x86_64-linux";
      };

    apps = forAllSystems (system: {
      home-manager = {
        type = "app";
        program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
      };
    });
  };
}
