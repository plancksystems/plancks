# Planck

Database + control plane + CLI for shipping small-to-mid-sized apps
without standing up a separate operational stack. One release tarball
gives you three binaries:

- **`planck`**: the database engine (storage, wire protocol, optional
  WASM hosting, change streams, replication). See [planck/](planck/).
- **`workbench`**: control plane and web UI on port 2369 (identity,
  supervision, query editor, deploy receiver, scheduler, backup /
  restore). See [workbench/](workbench/).
- **`planctl`**: the CLI you use to set up the host, scaffold
  projects, deploy them, and tear them down. See [planctl/](planctl/).

A `wasmer` shared library ships alongside the binaries; `planck`
loads it at runtime when WASM hosting is enabled.

## Install

Pick the archive that matches your machine from the
[releases page](https://github.com/plancksystems/plancks/releases).

### macOS

macOS is a local / dev target, install under your home directory, no
`sudo`, no `/opt`. `~/.planck/bin` is exactly where `planctl system
init` looks for the binaries.

```sh
mkdir -p ~/.planck
tar -xzf ~/Downloads/planck-0.1.0-macos-arm64
.tar.gz -C ~/.planck --strip-components=1
```

Add the bin directory to your shell rc (`~/.zshrc`):

```sh
export PATH="$HOME/.planck/bin:$PATH"
```

### Linux

Linux is the production target, install under `/opt/planck`:

```sh
sudo mkdir -p /opt/planck
sudo tar -xzf ~/Downloads/planck-0.1.0-linux-amd6.tar.gz -C /opt/planck --strip-components=1
```

Add the bin directory to your shell rc (`~/.bashrc`):

```sh
export PATH="/opt/planck/bin:$PATH"
```

Reload your shell, then check the binaries are on `PATH`:

```sh
which planck planctl workbench
```

### Windows (PowerShell as Administrator)

```powershell
Expand-Archive -Path "$HOME\Downloads\planck-0.1.0-windows-amd64.zip" -DestinationPath .
New-Item -ItemType Directory -Force -Path 'C:\Program Files\Planck'
Move-Item .\planck-0.1.0-x86_64-windows\bin 'C:\Program Files\Planck\bin'
```

`planctl system init` expects the binaries at `C:\Program Files\Planck\bin`. Then open **Advanced System Settings**, go to **Environment Variables**, and add `C:\Program Files\Planck\bin` to both the User and System `Path` entries.

## Initialize the host

Before you can deploy anything, you need a workbench (the control plane) and a system database running on this host. One command sets both up:

```sh
planctl system init
```

What `system init` does:

1. Lays out the data directory under the OS-specific install root (`$HOME/.planck` on macOS, `/opt/planck` on Linux, `C:\Program Files\Planck` on Windows).
2. Drops a default `config.yaml` for workbench. (Config is YAML, always. No env-var overrides.)
3. Brings up the system database on port `23469`.
4. Registers `planck` and `workbench` as OS-managed services, launchd (macOS), systemd (Linux), or the Windows Service Manager, and starts them.

The install root and service manager are chosen automatically by the host OS; there is no flag to override them. (macOS registers launchd daemons too, it does not spawn the processes directly.)

## Initialize the host

`planctl system init` is a one-time setup that creates the data
directory layout, registers the supervised services, and installs the
system database that `workbench` uses for identity and orchestration.

```sh
planctl system init
```

What this does:

- Creates the install root (`~/.planck` on macOS, `/opt/planck` on
  Linux, `C:\Program Files\Planck` on Windows) with subdirectories for
  binaries, data, logs, and apps.
- Drops a default `config.yaml` for `workbench`.
- Provisions the system database (a `planck` instance on port 23469)
  with the built-in default `admin` user.
- Registers `planck` (system DB) and `workbench` as OS-managed
  services (launchd on macOS, systemd on Linux, SCM on Windows) and
  starts them.

The install root and service manager are selected automatically by the
host OS (see [planctl/README.md](planctl/README.md)). There is no flag
to override them.

Bring everything up:

```sh
planctl system start
```

Now visit [http://localhost:2369](http://localhost:2369) and the
workbench UI should answer. The first time you open it, log in as the
`admin` user with the built-in default admin key. Rotate it
immediately afterward (the `RegenerateKey` wire op / the workbench
admin action); the default is well-known and baked into the engine.

`planctl system stop` shuts it all down again; `planctl system
deinit` unregisters the supervised services but leaves data and
binaries in place.

## First project

Once `workbench` is up, point `planctl` at it with a profile in
`~/.planctl/config.yaml` (every deploy command takes `--profile`):

```yaml
profiles:
  - name: dev
    nodes:
      - server: http://127.0.0.1:2369
        uid: admin
        key: <the default admin key>
```

Then scaffold and deploy:

```sh
# scaffold a hypermedia + monolith starter project
planctl new mystore --type hda --arch mono
cd mystore

# Set a unique HTTP port in app/service.yaml and a wire port in
# app/db.yaml. Both ship as 0, and deploy rejects port 0.

# Deploy to the local workbench. This builds the app for you, then
# uploads it (mono project → --arch mono).
planctl deploy --app --arch mono --profile dev
```

Open the HTTP port you set in `app/service.yaml` (for example
`http://localhost:3010`) for the app, or go back to the workbench UI to
inspect schema, run PQL queries, and watch live stats.

Templates:

| Type  | Arch    | What you get                                                              |
| ----- | ------- | ------------------------------------------------------------------------- |
| `hda` | `mono`  | Hypermedia (datastar) monolith, single binary                             |
| `hda` | `micro` | Hypermedia microservices: shell + per-feature WASM services + SSE service |
| `spa` | `mono`  | Vue 3 SPA + single JSON API, single binary                                |
| `spa` | `micro` | Vue 3 SPA + per-feature JSON services + SSE service                       |

Full command reference is in [planctl/README.md](planctl/README.md).

## Repository layout

```
planck/
├── planck/         # the database engine (binary: planck)
├── workbench/      # control plane + UI (binary: workbench)
├── planctl/        # CLI (binary: planctl)
├── ui/             # Vue 3 source for the workbench UI
├── wasmer-zig-api/ # vendored wasmer bindings
├── build.zig       # top-level orchestrator (release tarballs, install-dev)
└── .github/        # release workflow
```

Each subproject is a standalone Zig project with its own
`build.zig`, `build.zig.zon`, and README. Cross-project deps are
pinned by relative path so the whole repo builds without network
access once you've fetched it.

## Build from source

```sh
git clone https://github.com/plancksystems/planck
cd planck

# build all three binaries (Debug) and copy them to ~/.planck/bin
zig build install-dev

# or build a release tarball into ../ws/dist/downloads/
zig build release -Dversion=0.1.0
```

`install-dev` is the daily driver: it rebuilds `planctl`,
`workbench`, and `planck` in Debug mode and drops them at
`~/.planck/bin/{planctl,workbench,planck}`, ready for `planctl
system start`.

The release step (`zig build release`) produces the same archive
shape the GitHub workflow ships:

```
planck-<version>-<arch>-<os>/
├── bin/
│   ├── planck
│   ├── workbench
│   ├── planctl
│   └── libwasmer.so   # libwasmer.dylib on macOS, wasmer.dll on Windows
├── VERSION
└── README.md
```

Minimum Zig version: 0.16.0. macOS / Linux release builds also need
`npm` for the workbench UI bundle.

## License

Mixed, per subproject:

- [planck/](planck/) (the database engine): Business Source License 1.1.
  Production use is fine; offering planck itself as a managed
  database-as-a-service to third parties is restricted. Converts to
  Apache 2.0 four years after each release. See
  [planck/LICENSE](planck/LICENSE).
- [workbench/](workbench/), [planctl/](planctl/), [ui/](ui/): MIT.
- Vendored / pinned dependencies (`wasmer-zig-api/`, third-party
  crates referenced by path or URL): under their upstream licenses.
