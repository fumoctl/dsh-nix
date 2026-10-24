# dsh-nix

Nix-native packaging for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`):

1. **`pkgs.dsh`** — the CLI as a reproducible Nix package (pnpm monorepo build,
   upstream pinned at `687f282`, v0.2.1-rc.2).
2. **Profile packager** — compose DSH profiles from three kinds of plugins in
   one ordered list, with build-time resolution instead of `dsh plugin`'s
   activation-time pnpm reconcile.
3. **`programs.dsh` Home Manager module** — declarative plugin management in
   the Thunderbird style: the module owns the composition under `~/.dsh`,
   the app owns its data.

## Plugin model

A profile's `plugins` list accepts three kinds, mixed in any order:

| Kind | Example | Resolution |
|---|---|---|
| in-box bundle | `"@deepseek-ai/dsh-base"` | name only; resolved from the `dsh` installation |
| pnpm spec | `"github:someone/plugin"` | fixed-output derivation runs `pnpm add` at build time; pin with `specsHash` |
| Nix package/path | `pkgs.fetchFromGitHub { ... }` or `./my-plugin` | symlinked into the profile; carries its own dependency closure |

Layer registration (which plugins join `dsh.profile.bundles`) is a pure
build-time reconcile that reads each resolved package's `dsh.bundle.patch`
declaration — `dsh plugin`'s install/resolve/reconcile is replaced wholesale,
so removal is declarative and resolution failures surface at `nix build`.

In-box profiles get a **build-time boot check**: `checks.profile-boot-web`
and `checks.profile-boot-headless` boot the composed profile with dsh's own
`boot()` (which runs `assertEntriesActivated`) inside the Nix sandbox and
dispose immediately. A profile that would fail at runtime — missing
services, failed activation — fails `nix build` instead. The check is the
real dsh fail-loud, not a reimplementation: `scripts/check-profile.mjs`
loads the profile exactly as `dsh --profile` would and lets dsh's own
audit decide. `checks.profile-boot-web-nobase` proves the check catches a
web-app-without-base composition (8 pending entries).

## Declaring plugins

A profile is an ordered `plugins` list. Order matters: layers are registered
in `dsh.profile.bundles` in list order. Each entry is classified by its
shape, so you never state its kind explicitly.

### 1. In-box bundles (plain strings)

Names shipped with the `dsh` install (`@deepseek-ai/dsh-base`,
`@deepseek-ai/dsh-web-app`, `@deepseek-ai/dsh-headless`). Nothing is fetched.

```nix
plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
```

### 2. pnpm specs (any other string)

Anything else — `github:owner/repo`, `file:/path`, an npm name — is resolved
by a fixed-output derivation running `pnpm add`. Pin it with `specsHash`:

```nix
plugins = [ "@deepseek-ai/dsh-base" "github:someone/cool-plugin" ];
specsHash = "";   # discovery mode: build once, copy the hash from the error
```

Leave `specsHash` empty only while discovering; Nix then reports the real
hash, which you paste back in. One `specsHash` covers all specs of a profile.

### 3. Nix plugins (paths, derivations, `mkPluginBundle`)

A local directory, a fetched source, or an explicit `mkPluginBundle`:

```nix
plugins = [
  ./my-plugin                                   # local dir with package.json
  (pkgs.fetchFromGitHub { owner = "..."; repo = "..."; rev = "..."; hash = "..."; })
  (plugins.mkPluginBundle {                     # explicit, for derivations
    packageName = "@me/thing";                  # required unless package.json has a name
    path = someDerivation;
    patchPath = "cordis.patch.yml";             # optional override of dsh.bundle.patch
  })
];
```

The plugin is symlinked into the profile's `node_modules/<packageName>`.
`packageName`s must be unique across Nix plugins.

### What a plugin directory looks like

A plugin joins the layer list only if its `package.json` declares a patch;
otherwise it is just a dependency available in `node_modules`.

```jsonc
// package.json
{
  "name": "@me/my-plugin",
  "type": "module",
  "exports": { "./plugin": "./plugin.mjs" },
  "dsh": { "bundle": { "patch": "cordis.patch.yml" } }
}
```

```yaml
# cordis.patch.yml — imported verbatim, never transcribed by Nix
- insert:
    - id: my-plugin
      name: ./node_modules/@me/my-plugin/plugin.mjs
      config: { }
```

`plugin.mjs` exports `apply(ctx, config)`. See `examples/plugins/tui-core/`
for a working fixture.

### A full profile

```nix
profiles.custom = {
  plugins = [
    "@deepseek-ai/dsh-base"        # in-box
    "github:someone/cool-plugin"   # spec, pinned by specsHash
    ./my-plugin                    # Nix path
  ];
  specsHash = "sha256-...";
  userPatchesFile = ./patches.yml; # optional profile-level cordis.patch.yml
};
```

Outside Home Manager, the same fields go to `profilesLib.mkProfileBundle`
(plus `name` and `inBoxNames`); see `examples/profiles/`. Duplicate
`packageName`s or an empty profile name fail at evaluation.

## Usage

### Overlay

```nix
# nixos configuration:
imports = [ inputs.dsh-nix.nixosModules.default ];   # or:
nixpkgs.overlays = [ inputs.dsh-nix.overlays.default ];

# now pkgs.dsh is available everywhere:
environment.systemPackages = [ pkgs.dsh ];
```

The Home Manager module's `package` option defaults to `pkgs.dsh` when the
overlay is applied, falling back to a self-contained `callPackage` build.

### Home Manager (Complete Example)

Below is a complete, annotated example showing how to wire `dsh-nix` into Home
Manager with:
- shared MCP servers (`@deepseek-ai/dsh-mcp-client`, both local `stdio` and remote `streamable-http`) via `userPatches`,
- a `headless` CLI profile,
- a `web` profile with a third-party theme plugin (`@nonamelego/dsh-catppuccin`), and
- a `tui` profile using [`dsh-TUI`](https://github.com/ccch1mneyyy/dsh-TUI) (`@deepseek-harness-tui/dsh-tui`).

Adapt or remove the example MCP servers, plugins, and profiles to match your own setup:

```nix
# In your flake.nix inputs:
inputs.dsh-nix.url = "github:fumoctl/dsh-nix";
inputs.dsh-nix.inputs.nixpkgs.follows = "nixpkgs";

# In your Home Manager module (e.g. home/shell.nix):
imports = [ inputs.dsh-nix.homeManagerModules.dsh ];

programs.dsh =
  let
    # Example shared `userPatches` list.
    # `@deepseek-ai/dsh-mcp-client` is already bundled inside `pkgs.dsh` (it is a
    # Cordis plugin, not a profile bundle with `dsh.bundle.patch`), so it is
    # enabled through `userPatches` with one `insert` entry per MCP server
    # rather than added to `plugins`.
    mcpPatches = [
      {
        insert = [
          {
            # Example 1: Local `stdio` MCP server (here invoking the CLI bundled
            # inside the VSCodium DBCode extension; tools become `mcp__dbcode__*`).
            # Always use absolute `/nix/store/...` paths for `command`.
            id = "mcp-dbcode";                  # unique Cordis entry id
            name = "@deepseek-ai/dsh-mcp-client";
            config = {
              serverName = "dbcode";            # [A-Za-z0-9_-]{1,32}
              transport = "stdio";
              command = "${pkgs.bash}/bin/bash";
              args = [
                "-c"
                ''exec ${pkgs.nodejs}/bin/node "$(ls -d "$HOME"/.vscode-oss/extensions/dbcode.dbcode-*/out/cli/dbcode | sort -V | tail -n1)" mcp''
              ];
            };
          }
          {
            # Example 2: Remote `streamable-http` MCP server
            # (tools become `mcp__rivalsearch__*`).
            id = "mcp-rivalsearch";
            name = "@deepseek-ai/dsh-mcp-client";
            config = {
              serverName = "rivalsearch";
              transport = "streamable-http";
              url = "https://RivalSearchMCP.fastmcp.app/mcp";
            };
          }
        ];
      }
    ];
  in
  {
    enable = true;

    # 1. Headless profile (`dsh --profile headless "task"`):
    #    Uses only in-box bundles shipped with `pkgs.dsh`, so no `specsHash` is needed.
    profiles.headless = {
      plugins = [
        "@deepseek-ai/dsh-base"      # core services (must come first)
        "@deepseek-ai/dsh-headless"  # one-shot CLI runner
      ];
      userPatches = mcpPatches;
    };

    # 2. Web UI profile (`dsh --profile web`):
    #    Combines the in-box web bundle with a third-party npm plugin spec.
    #    Also syncs Catppuccin palettes to `~/.dsh-tui/themes/` on activation.
    profiles.web = {
      plugins = [
        "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-web-app"
        "@nonamelego/dsh-catppuccin@0.6.2"  # pnpm spec resolved at build time
      ];
      # Pin the fixed-output derivation for all pnpm specs in this profile.
      # Set `specsHash = "";` first to let `nix build` report the real hash.
      specsHash = "sha256-Ophk7VuohWNwRSsX+9ktMVFwA9JFXuumvnKdzqcAhgE=";
      userPatches = mcpPatches;
    };

    # 3. Terminal UI profile (`dsh --profile tui`):
    #    Upstream dsh ships no TUI bundle; this layers the community `dsh-TUI`
    #    plugin (`https://github.com/ccch1mneyyy/dsh-TUI`) on top of `dsh-base`.
    profiles.tui = {
      plugins = [
        "@deepseek-ai/dsh-base"
        "@deepseek-harness-tui/dsh-tui@0.16.1"
      ];
      specsHash = "sha256-KqSShSzXYsDVLY05tNl2mz/MDTl2Hxzs5m53V/l19+8=";
      userPatches = mcpPatches;
    };

    # Optional: machine-wide patch file written to `~/.dsh/cordis.patch.yml`.
    # Useful when you need YAML `!!js` expressions (e.g. `process.env.TOKEN`),
    # since inline `userPatches` is JSON-serialisable only.
    # homePatchesFile = ./home-patches.yml;
  };
```

Activation materialises each immutable profile into
`~/.dsh/profiles/<name>` (stamp-based idempotent refresh via `.dsh-nix-stamp`).
When a profile's Nix store path changes, activation performs a 3-way merge of
the new declarative `cordis.patch.yml`, the previous Nix-declared
`.dsh-nix-patch.yml`, and the live `~/.dsh/profiles/<name>/cordis.patch.yml` so
runtime settings, custom providers, and custom models saved in the UI survive
profile rebuilds without duplicating Nix-declared entries. Sessions and
credentials under `~/.dsh` remain the app's.

```sh
dsh --profile headless "task"
dsh --profile web          # http://127.0.0.1:3080
dsh --profile tui          # interactive terminal UI
```

#### Example: Desktop entry for the Web UI

As an optional convenience, you can declare an XDG `.desktop` launcher entry in
Home Manager that starts `dsh --profile web` in the background on first click
and re-opens the existing authenticated URL on subsequent clicks (instead of
failing with `EADDRINUSE` on port `3080`):

```nix
xdg.desktopEntries.dsh-web = {
  name = "DeepSeek Harness Web";
  genericName = "AI Coding Agent";
  comment = "Launch the DeepSeek Harness Web UI";
  # Uses the official SVG icon bundled inside `pkgs.dsh`:
  icon = "${config.programs.dsh.package}/apps/desktop/resources/icon.svg";
  terminal = false;
  categories = [ "Development" "Utility" ];
  exec = toString (
    pkgs.writeShellScript "dsh-web-launch" ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
      pid_file="$runtime_dir/dsh-web.pid"
      url_file="$runtime_dir/dsh-web.url"

      # If the daemon is already running and we recorded its tokenized URL,
      # open a new browser tab to that URL and exit.
      if [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null && [ -s "$url_file" ]; then
        exec ${pkgs.xdg-utils}/bin/xdg-open "$(cat "$url_file")"
      fi

      # Clean up any stale `dsh --profile web` process (`bin/dsh` is a
      # `makeWrapper` binary whose `/proc/<pid>/cmdline` is `.../apps/cli/lib/bin.js`).
      ${pkgs.procps}/bin/pkill -u "$USER" -f 'apps/cli/lib/bin\.js --profile web' 2>/dev/null || true
      rm -f "$pid_file" "$url_file"

      # Record this shell's PID before `exec` so the `node` process inherits it,
      # then capture the `dsh web: http://127.0.0.1:3080/?token=...` startup line.
      umask 077
      printf '%s\n' "$$" > "$pid_file"
      exec ${config.programs.dsh.package}/bin/dsh --profile web > >(
        while IFS= read -r line; do
          case "$line" in
            "dsh web: http"*)
              umask 077
              printf '%s\n' "''${line#dsh web: }" > "$url_file"
              ;;
          esac
        done
      )
    ''
  );
};
```

#### Impermanence / State Persistence

If your root filesystem is ephemeral, persist these directories in `$HOME`:
- `.dsh` — core DSH state (`.credentials.yaml`, `sessions/`, `storages/`, `profiles/`)
- `.dsh-tui` — `dsh-TUI` preferences (`theme.json`, `themes/`, `effort.json`, `extension-grants.json`)
- `.agents` — optional shared user-level agent/skills root (`$DSH_AGENTS_HOME`)

### Standalone

```nix
nix build .#packages.x86_64-linux.dsh        # the CLI
nix build .#packages.x86_64-linux.tui-spec   # example: spec-resolved profile
nix eval .#profiles.tui-spec --json          # the declaration
```

The package also ships `dsh-acp-demo`, the ACP automation server app
(JSON-RPC over stdio; supply a leaf `cordis.yml` via `--config`, e.g. the
upstream `examples/acp-agent/cordis.yml`).

## Verification

```sh
nix flake check                    # artifact shape + module assertions
./scripts/profile-smoke.sh         # boot tui profile with packaged dsh,
                                   # assert activate/dispose lifecycle
./scripts/hm-e2e.sh                # module eval -> activation -> boot
```

Real agent runs need credentials (`DEEPSEEK_API_KEY`, or configure the model
in the web UI so `~/.dsh/.credentials.yaml` is populated).

## Notes

- The Home Manager module's default `package` builds `pkgs/dsh.nix` against
  your nixpkgs, which must provide `fetchPnpmDeps` and `pnpmConfigHook`.
- Spec-string plugins change their resolved content only when their
  `specsHash` is updated — deliberate lockfile-style ceremony.
- Upstream `dsh` ships no TUI surface (only `web` and `headless` profiles);
  a third-party TUI bundle would slot in as one plugin entry.

## License

MIT
