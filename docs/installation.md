# Building and installation

Geri uses a Mix release, including the Erlang runtime and compiled Elixir
application. Build separately on each operating system and architecture.
The installer and launcher use `/bin/sh` and standard Unix tools;
GNU coreutils are not required. Native builds and terminal behavior still
need testing on each supported target.

## Build with the TUI

Build prerequisites: Elixir 1.20 and a compatible Erlang/OTP installation.
A build with TUI support also requires ExRatatui's native Ratatui library,
either as a precompiled binary for your platform or built from source.
Fetching dependencies requires network access.

From the Geri source directory:

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release --overwrite
```

`mix release` compiles the production application as needed. A separate
`mix compile` or `mix escript.build` is not required to install this release.
For development, `./geri.sh upload ...` continues to use
`_build/prod/rel/geri`.

## Headless install

Use a headless install if ExRatatui/Ratatui is unavailable on your platform,
or if you do not need a terminal UI. The `GERI_TUI=false` build option
excludes ExRatatui and its native library.
This route requires Elixir and Erlang at build time, but no Rust toolchain
or terminal UI library. It retains posting, checking, repair, NZB output,
and graceful signal cancellation. Requesting `--tui` returns an error.

```sh
GERI_TUI=false MIX_ENV=prod mix deps.get
GERI_TUI=false MIX_ENV=prod mix release --overwrite
./install.sh --prefix "$HOME/.local" --release _build/headless/prod/rel/geri
```

This release is built in `_build/headless/prod/rel/geri`, independently of
the normal build. Keep `GERI_TUI=false` on all Mix commands for this variant.
The installed release does not need that environment variable.

Run the core regression tests with:

```sh
GERI_TUI=false mix test test/failure_reporting_test.exs test/upload_duplicates_test.exs test/control_test.exs test/inspection_test.exs test/ui_window_test.exs
```

The TUI input test is separate (`test/tui_input_test.exs`) and only defines
tests when the TUI is present. The core regression command above does not require a terminal.

## Choose an installation prefix

For a personal installation (no root required):

```sh
./install.sh --prefix "$HOME/.local"
```

For a system installation:

```sh
sudo ./install.sh --prefix /usr/local
```

For the headless release, supply its build directory explicitly:

```sh
./install.sh --prefix "$HOME/.local" --release _build/headless/prod/rel/geri
# Or install system-wide, after building as your normal user:
sudo ./install.sh --prefix /usr/local --release _build/headless/prod/rel/geri
```

The installer only copies an already built release; it does not run Mix,
fetch dependencies, or require root for building. If `sudo` is unavailable,
run the installation command from a root shell, with the source directory
as the working directory.

For prefix `/usr/local`, the layout is:

| Path | Purpose |
|---|---|
| `/usr/local/bin/geri` | Symlink to the installed `geri.sh` |
| `/usr/local/lib/geri/geri.sh` | Geri CLI launcher and signal bridge |
| `/usr/local/lib/geri/bin/geri` | Generated Mix release management script |
| `/usr/local/lib/geri/lib/` | Compiled application and libraries |
| `/usr/local/lib/geri/releases/` | Release metadata and configuration |
| `/usr/local/lib/geri/erts-*/` | Bundled Erlang runtime |
| `/usr/local/lib/geri/README.md`, `docs/`, `LICENSE` | Documentation |

Add the prefix's `bin` directory to your shell's PATH if necessary:

```sh
export PATH="$HOME/.local/bin:$PATH"
geri --help
geri --version
```

The launcher follows absolute or relative symlinks and preserves your
working directory. Input paths, globs, and relative NZB paths are evaluated
from the directory where you run Geri. Use the public `geri` command rather
than calling the Mix management script directly: the public launcher
preserves our signal handling and CLI exit status.

## Exit status and cancellation

The launcher returns the Geri exit status:

| Status | Meaning |
|---|---|
| 0 | Success |
| 1 | Upload, configuration, or other operational failure |
| 2 | Verification remained inconclusive |
| 130 | Graceful cancellation |

Capture `$?` immediately after running Geri to record or act on its status.
SIGTERM sent to the public launcher requests graceful cancellation;
unfinished NZBs remain as `.part`.

## Upgrade and remove

Stop running jobs before upgrading. Rebuild, then rerun the installer with
the same prefix and chosen release path. It replaces its recognized release
directory rather than merging old release files. It refuses to overwrite an
unrelated command or an unrecognized installation directory.
User credentials, source files, NZBs, and redirected logs are outside
the installed release and are not touched.

To remove the system installation, after stopping jobs:

```sh
sudo rm /usr/local/bin/geri
sudo rm -r /usr/local/lib/geri
```

For a personal installation, use the corresponding `$HOME/.local` paths
without `sudo`.
