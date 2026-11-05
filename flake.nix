{
  description = "FigCraft — native interface design and prototyping, in pure Rust";

  inputs = {
    # FigCraft needs edition 2024 and rustc ≥ 1.95, so the flake tracks unstable. Consumers on a
    # release channel can retarget it: `inputs.figcraft.inputs.nixpkgs.follows = "nixpkgs";`
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Optional build input of the repository: the fonts that `crates/text/build.rs` embeds when
    # `CRAFT_FONTS_DIR` is set. Official releases always build with them; without them everything
    # works but non-Latin text lacks glyphs. Pinned to the revision `.github/workflows/ci.yml` and
    # `release.yml` fetch — bump all of them together (`nix flake update craft-fonts`).
    craft-fonts = {
      url = "github:storytold/craft-fonts/37827adc41fd165f9a9234ac40f94dbad353aa69";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      craft-fonts,
    }:
    let
      inherit (nixpkgs) lib;

      # No x86_64-darwin: the pinned nixpkgs dropped it. On an Intel Mac, retarget nixpkgs at a
      # release that still has it, or install the release build.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The AppStream metadata carries a release date. The flake source's own commit date is
      # reproducible, unlike "now"; a tarball or dirty tree without one falls back to the epoch.
      buildDate =
        let
          d = self.lastModifiedDate or "";
        in
        if builtins.stringLength d >= 8 then
          "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
        else
          "1970-01-01";

      packageArgs = {
        inherit craft-fonts buildDate;
      };

      forAllSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (
        pkgs: _:
        let
          figcraft = pkgs.callPackage ./nix/package.nix packageArgs;
        in
        {
          inherit figcraft;
          default = figcraft;
        }
      );

      # `nixpkgs.overlays = [ inputs.figcraft.overlays.default ]` → `pkgs.figcraft` everywhere.
      overlays.default = final: _prev: {
        figcraft = final.callPackage ./nix/package.nix packageArgs;
      };

      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = lib.getExe self.packages.${system}.figcraft;
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system:
        let
          figcraft = self.packages.${system}.figcraft;
        in
        {
          default = pkgs.mkShell (
            {
              # The package's own native inputs, so `cargo run` in the shell needs no extra setup.
              inputsFrom = [ figcraft ];
              packages = with pkgs; [
                cargo
                rustc
                clippy
                rustfmt
                rust-analyzer
              ];
              # `cargo run` dlopens the Vulkan loader, libwayland and libxkbcommon like the packaged binary.
              LD_LIBRARY_PATH = lib.makeLibraryPath figcraft.passthru.runtimeLibs;
              RUST_BACKTRACE = "1";
            }
            // lib.optionalAttrs (craft-fonts != null) {
              # Embedded fonts in `cargo run` too; build.rs reads this as CRAFT_FONTS_DIR.
              CRAFT_FONTS_DIR = toString craft-fonts;
            }
          );
        }
      );

      checks = forAllSystems (
        pkgs: system:
        let
          figcraft = self.packages.${system}.figcraft;
        in
        {
          figcraft = figcraft;

          # Both module entry points evaluate with `enable = true` (no full NixOS evaluation).
          modules = pkgs.callPackage ./nix/module-check.nix { inherit figcraft; };

          # `nix fmt` formats the flake; this keeps it formatted.
          formatting = pkgs.runCommand "figcraft-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./nix}
            touch $out
          '';
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);

      # Both modules take the package from this flake unless `programs.figcraft.package` is set,
      # so `nixosModules.default`/`homeManagerModules.default` work without the overlay.
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./nix/module.nix { kind = "nixos"; }) ];
          _module.args.figcraftPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.figcraft;
        };

      homeManagerModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./nix/module.nix { kind = "home-manager"; }) ];
          _module.args.figcraftPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.figcraft;
        };
    };
}
