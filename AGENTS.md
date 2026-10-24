# AGENTS.md

Guidance for AI agents working in this repo. See [README.md](README.md) for user-facing docs.

## What this repo is

Nix-native packaging for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`). A flake with three layers:

1. `pkgs/dsh.nix` — builds the upstream pnpm monorepo into `bin/dsh` and `bin/dsh-acp-demo`.
2. `lib/` — the **profile packager**. It composes DSH profiles from an ordered plugin list and resolves them at build time (no `dsh plugin` reconcile at activation).
3. `modules/home-manager/dsh.nix` — the `programs.dsh` Home Manager module. It materialises profiles under `~/.dsh/profiles/<name>`.

Everything is Nix, plus a few shell/Node scripts. There is no app source here. The upstream `dsh` source comes in as a non-flake input.

## Layout

| Path | Role |
|---|---|
| `flake.nix` | Wires inputs, `packages`, `checks`, `devShells`, `overlays.default`, `nixosModules.default`, `homeManagerModules.dsh`, and the `lib`/`plugins`/`profilesLib`/`profiles` outputs. Holds the `inBoxNames` list and most checks. |
| `lib/plugins.nix` | `mkPluginBundle` (alias `mkPlugin`), `classifyPlugin`, `fetchSpecs`. |
| `lib/profiles.nix` | `mkProfileBundle` (alias `mkProfile`) is the pure declaration. `buildProfileBundle` (alias `buildProfile`) builds the artifact. |
| `modules/home-manager/dsh.nix` | Module options and the `home.activation.dshProfiles` script. |
| `pkgs/dsh.nix` | The `dsh` derivation. |
| `examples/profiles/*.nix` | Profile declarations: `tui`, `tui-spec`, `web`, `headless`, plus the optional `dsh-web`. |
| `examples/plugins/tui-core/` | Fixture plugin used by the tests (`package.json`, `cordis.patch.yml`, `plugin.mjs`). |
| `scripts/check-profile.mjs` | Boots a profile with dsh's own `boot()`. Used by the `profile-boot-*` checks. |
| `scripts/profile-smoke.sh`, `scripts/hm-e2e.sh` | Manual smoke and end-to-end scripts. They are not part of `nix flake check`. |
| `tests/home-module.nix` | Evaluation test for the HM module with stubbed `home.*` options. The `home-module` check runs it. |
| `tests/hm-activation.nix` | Helper for `hm-e2e.sh` that exposes `activation` and `artifact`. |

## Core concepts

- **Three plugin kinds** (see `classifyPlugin`):
  - `in-box`: a string that is in `inBoxNames`. It is resolved from the `dsh` install.
  - `spec`: any other string (`github:...`, `file:...`). A fixed-output derivation runs `pnpm add`, and `specsHash` pins the result.
  - `nix`: a path, derivation, or `mkPluginBundle` attrset. It is symlinked into `node_modules`.
- **Layer registration**: a plugin joins `dsh.profile.bundles` only if its `package.json` has `dsh.bundle.patch`. Order follows the plugin list.
- **Profile artifact**: `package.json`, `node_modules/`, `cordis.yml` (always `[]`), and `cordis.patch.yml`.
- **Home Manager ownership**: the module owns the composition. The app owns sessions, settings and credentials. `settings` is seed-only: written once if `settings.yaml` is absent. Profiles refresh only when the `.dsh-nix-stamp` differs from the artifact path.

## Commands

```sh
nix flake check                           # shape checks, HM module eval, boot checks
nix build .#dsh                           # the CLI (slow first build: pnpm deps)
nix build .#tui                           # example profile artifact
nix eval .#profiles.tui --json            # inspect a declaration
./scripts/profile-smoke.sh                # manual: boot tui with packaged dsh
./scripts/hm-e2e.sh                       # manual: HM eval -> activation -> boot
nix develop                               # nodejs_22, pnpm, yq-go
```

`flake.nix` defines `packages` for each system in `systems`. Use `nix flake show` to list the exact attribute names before building. `hm-e2e.sh` uses `<nixpkgs>` from `NIX_PATH`.

## Conventions and gotchas

- **Do not reimplement dsh/Cordis logic.** Plugin patches are imported verbatim, and validation goes through dsh's own `boot()`. Keep it that way. Earlier attempts at Nix-side validation of patches were reverted (see git log).
- **Updating upstream `dsh`** requires four coordinated edits:
  - the `inputs.dsh` rev in `flake.nix`,
  - `version` and `DSH_CLIENT_COMMIT_HASH` (the short rev) in `pkgs/dsh.nix`,
  - the `fetchPnpmDeps` `hash` in `pkgs/dsh.nix` (set it to `lib.fakeHash`, build, copy the reported hash),
  - then `nix flake lock`.
- **The README may drift.** Treat `flake.nix` (pinned `687f282`, v0.2.1-rc.2) and `pkgs/dsh.nix` as the source of truth, and fix the README when you touch the pin.
- `pkgs/dsh.nix` has deliberate patches that are fragile on version bumps: the `node-pty` `node-gyp rebuild`, the `sed` on `node-addon-require-builtin`, and the `--expose-internals` wrapper flag. Re-verify them on every upgrade.
- `fetchSpecs` uses an empty `specsHash` as discovery mode (`lib.fakeHash`). Do not commit profiles with an empty `specsHash` unless they have no specs.
- Duplicate `nix`-kind `packageName`s throw. An empty profile name throws.
- When you add an in-box bundle, update `inBoxNames` in `flake.nix`. Add `checks` entries for new profiles, following the existing `profile-boot-*` pattern.
- When you add a HM module option, extend `tests/home-module.nix` as well.
- Multi-system: avoid hard-coding `x86_64-linux` in new code. Only the README examples do that.
- `.gitignore` excludes `dsh` (an upstream checkout, used by `examples/profiles/dsh-web.nix`) and `result`. Do not commit either.
- Style: 2-space indentation, `{ lib }:`-style function headers, and comments that explain why. Keep shell inside Nix heredocs `set -e`-safe and escape with `lib.escapeShellArg`.

## Before finishing a change

1. Run `nix flake check`. Run `nix fmt`-style tidying only if a formatter is added later; none is configured now.
2. If you touched lib, the module, or a profile, also run `./scripts/profile-smoke.sh` and `./scripts/hm-e2e.sh` when feasible.
3. Keep the README in sync with any user-facing change.
