# Home Manager module factory for `programs.dsh`.
#
# Declarative plugin management in the Thunderbird style: the module owns the
# COMPOSITION layers under ~/.dsh (profiles/<name>/ + the home-level
# cordis.patch.yml), while the app owns its mutable data (settings.yaml after
# seeding, .credentials.yaml, sessions/, storages/).
#
# Activation materialises each immutable Nix-built profile into
# ~/.dsh/profiles/<name> (writable; dsh rewrites the profile root cordis.yml
# on every boot), comparing a stamp against the artifact store path.
#
# `plugins` accepts three kinds in one ordered list:
#   - in-box bundle names  ("@deepseek-ai/dsh-base")          name only
#   - pnpm spec strings    ("github:someone/plugin")          resolved at build
#     time by a fixed-output derivation; pin with `specsHash`
#   - Nix packages/paths   (pkgs.fetchFromGitHub { ... })     symlinked in
#
# Requires the user's nixpkgs to provide fetchPnpmDeps + pnpmConfigHook when
# `package` defaults to the callPackage-built dsh.
{ pluginsLib, profilesLib, inBoxNames, dshSrc }:

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.dsh;

  profileModule = lib.types.submodule {
    options = {
      plugins = lib.mkOption {
        type = lib.types.listOf (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]);
        default = [ ];
        description = ''
          Ordered plugin list. Each entry is one of: an in-box bundle name
          (@deepseek-ai/dsh-*), a pnpm spec string (resolved at build time;
          pin with specsHash), or a Nix package/path.
        '';
      };
      userPatchesFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Profile-level cordis.patch.yml (the DSH user patch layer).";
      };
      userPatches = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "Inline profile patch list (JSON-serialisable only; use userPatchesFile for !!js).";
      };
      specsHash = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Fixed-output hash pinning pnpm spec resolution for this profile.";
      };
    };
  };

  declarations = lib.mapAttrs (name: p:
    profilesLib.mkProfileBundle {
      inherit name;
      inherit (p) userPatchesFile userPatches specsHash;
      plugins = p.plugins;
      inherit inBoxNames;
    }) cfg.profiles;

  artifacts = lib.mapAttrs (name: declaration:
    profilesLib.buildProfileBundle { inherit pkgs; profile = declaration; }) declarations;

  profileDir = name: "$HOME/.dsh/profiles/" + lib.escapeShellArg name;
  stampFile = name: "${profileDir name}/.dsh-nix-stamp";
  declPatchFile = name: "${profileDir name}/.dsh-nix-patch.yml";

  # DSH 0.2+ persists UI settings, custom providers, and custom models as
  # `{ id, name, config }` entries inside `~/.dsh/profiles/<name>/cordis.patch.yml`.
  # When re-materialising a profile after its Nix store path changes, perform a
  # 3-way merge of:
  #   - fi == 0 ($decl):    new declarative `$artifact/cordis.patch.yml`
  #   - fi == 1 ($prev):    previous live `~/.dsh/profiles/<name>/cordis.patch.yml`
  #   - fi == 2 ($oldDecl): previous declarative `.dsh-nix-patch.yml`
  # Declarative `insert` blocks and Nix-owned `id`s are replaced (or removed if
  # dropped from Nix), while runtime entries added by DSH (`ConfigEditor`) are
  # preserved without duplication.
  mergePatchExpr = ''
    ((select(fi == 0) // []) | .. style="") as $decl
    | ((select(fi == 1) // []) | .. style="") as $prev
    | ((select(fi == 2) // []) | .. style="") as $oldDecl
    | (($decl + $oldDecl) | map(select(has("id") and (has("insert") | not)) | .id)) as $nixIds
    | ($prev | map(select(has("id") and (has("insert") | not)) | select(([.id] - $nixIds) | length > 0))) as $kept
    | ($decl + $kept)
    | (select(length == 0) | . style="flow") // .
  '';

  activateProfile = name: artifact:
    let
      dir = profileDir name;
      stamp = stampFile name;
      declPatch = declPatchFile name;
      artifactString = toString artifact;
      yq = "${pkgs.yq-go}/bin/yq";
    in
    ''
      if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = ${lib.escapeShellArg artifactString} ]; then
        :
      else
        prev_patch=""
        old_decl=""
        if [ -f "${dir}/cordis.patch.yml" ]; then
          prev_patch=$(mktemp)
          cp "${dir}/cordis.patch.yml" "$prev_patch"
          old_decl=$(mktemp)
          if [ -f "${declPatch}" ]; then
            cp "${declPatch}" "$old_decl"
          else
            printf '[]\n' > "$old_decl"
          fi
        fi
        rm -rf "${dir}"
        mkdir -p "${dir}"
        cp -rL ${lib.escapeShellArg artifactString}/. "${dir}/"
        # cp -rL syncs the destination directory attributes (read-only store
        # modes) too; dsh rewrites the profile root cordis.yml on every boot.
        chmod -R u+w "${dir}"
        cp "${dir}/cordis.patch.yml" "${declPatch}"
        if [ -n "$prev_patch" ]; then
          if merged=$(${lib.escapeShellArg yq} eval-all ${lib.escapeShellArg mergePatchExpr} "${declPatch}" "$prev_patch" "$old_decl" 2>/dev/null); then
            printf '%s\n' "$merged" > "${dir}/cordis.patch.yml"
            chmod 600 "${dir}/cordis.patch.yml"
          fi
          rm -f "$prev_patch" "$old_decl"
        fi
        printf '%s' ${lib.escapeShellArg artifactString} > "${stamp}"
      fi
    '';

  activateSettings = lib.optionalString (cfg.settings != { }) ''
    if [ ! -f "$HOME/.dsh/settings.yaml" ]; then
      mkdir -p "$HOME/.dsh"
      umask 077
      cat > "$HOME/.dsh/settings.yaml" <<'DSH_NIX_SETTINGS'
    ${builtins.toJSON cfg.settings}
    DSH_NIX_SETTINGS
    fi
  '';
in
{
  options.programs.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness (dsh)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dsh or (pkgs.callPackage ../../pkgs/dsh.nix { src = dshSrc; });
      defaultText = "pkgs.dsh (via inputs.dsh-nix.overlays.default) or callPackage fallback";
      description = "The dsh CLI package to install.";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profileModule;
      default = { };
      description = "DSH profiles materialised under ~/.dsh/profiles/<name>.";
    };

    homePatchesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Machine-level patch layer written to ~/.dsh/cordis.patch.yml.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Seed-only settings.yaml content; after first activation the app owns the file.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.file = lib.mkIf (cfg.homePatchesFile != null) {
      ".dsh/cordis.patch.yml".source = cfg.homePatchesFile;
    };

    home.activation.dshProfiles =
      lib.concatStringsSep "\n" (lib.mapAttrsToList activateProfile artifacts)
      + "\n" + activateSettings;
  };
}
