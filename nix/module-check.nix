# Evaluates both module entry points with `enable = true` and checks what they configure.
#
# `lib.evalModules` plus stub declarations of the handful of NixOS/home-manager options the module
# touches: a full NixOS evaluation would need the whole nixpkgs module set, and the stubs keep the
# check to the module's own contract. A wrong option type, a missing option, or a behaviour that
# regresses fails evaluation, so `nix flake check` catches it.
{
  lib,
  pkgs,
  figcraft,
}:

let
  inherit (lib) mkEnableOption mkOption types;

  palette = ../packaging/linux/ai.storyteller.figcraft.desktop;

  configHome = "/home/test/.config";
  settingsFile = "${configHome}/FigCraft/settings.override.json";

  desktopFile = "ai.storyteller.figcraft.desktop";

  # Must match `packaging/linux/ai.storyteller.figcraft.desktop`.
  mimeTypes = [
    "application/x-figcraft"
    "image/svg+xml"
    "image/png"
    "image/jpeg"
    "application/x-sketch"
    "x-scheme-handler/figcraft"
  ];

  expected = lib.genAttrs mimeTypes (_: [ desktopFile ]);

  nixosStub = _: {
    options = {
      environment.systemPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      environment.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.mime.defaultApplications = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
      };
    };
  };

  homeStub = _: {
    options = {
      home.packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      home.file = mkOption {
        type = types.attrsOf types.anything;
        default = { };
      };
      home.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.configHome = mkOption {
        type = types.str;
        default = configHome;
      };
      xdg.mimeApps = mkOption {
        default = { };
        type = types.submodule {
          options = {
            enable = mkEnableOption "mimeApps";
            defaultApplications = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
            associations.added = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
          };
        };
      };
    };
  };

  evalModule =
    kind: setAsDefault: settings:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        (import ./module.nix { inherit kind; })
        (if kind == "nixos" then nixosStub else homeStub)
        {
          programs.figcraft = {
            enable = true;
            package = figcraft;
            inherit setAsDefault settings;
            paletteFile = palette;
          };
        }
      ];
    };

  nixos = evalModule "nixos" true { author = "Nix"; };
  nixosPlain = evalModule "nixos" false { };
  home = evalModule "home-manager" true { author = "Nix"; };
  homePlain = evalModule "home-manager" false { };

  assertions = [
    {
      what = "nixos installs the package";
      ok = nixos.config.environment.systemPackages == [ figcraft ];
    }
    {
      what = "nixos mime defaults";
      ok = nixos.config.xdg.mime.defaultApplications == expected;
    }
    {
      what = "nixos palette variable";
      ok = nixos.config.environment.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "nixos mime defaults without setAsDefault";
      ok = nixosPlain.config.xdg.mime.defaultApplications == { };
    }
    {
      what = "nixos writes no settings";
      ok = !builtins.hasAttr "home" nixosPlain.config;
    }
    {
      what = "home-manager installs the package";
      ok = home.config.home.packages == [ figcraft ];
    }
    {
      what = "home-manager mime defaults";
      ok = home.config.xdg.mimeApps.defaultApplications == expected;
    }
    {
      what = "home-manager mime associations";
      ok = home.config.xdg.mimeApps.associations.added == expected;
    }
    {
      what = "home-manager palette variable";
      ok = home.config.home.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "home-manager writes the overlay";
      ok = builtins.hasAttr settingsFile home.config.home.file;
    }
    {
      what = "home-manager writes no overlay for empty settings";
      ok = !builtins.hasAttr settingsFile homePlain.config.home.file;
    }
    {
      what = "home-manager leaves mimeApps alone without setAsDefault";
      ok = homePlain.config.xdg.mimeApps.enable == false;
    }
  ];

  failed = map (a: a.what) (lib.filter (a: !a.ok) assertions);
in
assert lib.assertMsg (failed == [ ]) "figcraft modules: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "figcraft-module-check" { } ''
  grep -q 'author' ${home.config.home.file.${settingsFile}.source}
  grep -q 'Nix' ${home.config.home.file.${settingsFile}.source}
  touch $out
''
