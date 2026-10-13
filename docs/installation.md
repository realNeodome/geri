# Building and installation

Geri uses a Mix release, including the Erlang runtime and compiled Elixir
application. Build separately on each operating system and architecture.
The installer and launcher use `/bin/sh` and standard Unix tools;
GNU coreutils are not required. Native builds and terminal behavior still
need testing on each supported target.

## Install dependencies and get the source

Geri requires Elixir 1.20 and a compatible Erlang/OTP installation. The
examples below use macOS (OS X) with [Homebrew](https://brew.sh/).
Install Elixir first:

```sh
brew install elixir
elixir --version
```

Homebrew installs Erlang/OTP as a dependency. For other operating systems,
follow the [Elixir installation instructions](https://elixir-lang.org/install/)
and check that the installed Elixir version meets Geri's requirement.

Install Git if needed, then clone Geri and set up Hex, Mix's package manager:

```sh
brew install git
git clone https://github.com/realNeodome/geri.git
cd geri
mix local.hex --force
```

Fetching dependencies requires network access. A build with TUI support
also requires ExRatatui's native Ratatui library, either as a precompiled
binary for your platform or built from source. If it is unavailable, use
the headless installation below.

## Build and install with the TUI

From the Geri source directory:

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release --overwrite
./install.sh
```

`./install.sh` installs into `/usr/local` by default. If elevated permissions
are needed, run only this step with `sudo ./install.sh` or from a root shell.
Build as your normal user. For a personal installation without root, use
`./install.sh --prefix "$HOME/.local"` instead.

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
./install.sh --release _build/headless/prod/rel/geri
```

The same prefix and permissions choices apply: the command above installs
into `/usr/local`; add `--prefix "$HOME/.local"` for a personal installation.

This release is built in `_build/headless/prod/rel/geri`, independently of
the normal build. Keep `GERI_TUI=false` on all Mix commands for this variant.
The installed release does not need that environment variable.

Run all regression tests for the headless build with:

```sh
GERI_TUI=false mix test
```

The TUI input tests only run when the TUI is present, so the headless test
suite does not require a terminal. Some network tests exercise real timeouts;
allow roughly 90 seconds for the suite.

## Choose an installation prefix

For the default installation into `/usr/local`:

```sh
./install.sh
```

If `/usr/local` requires elevated permissions, use `sudo ./install.sh` or
run it from a root shell. Build the release as your normal user.

For a personal installation (no root required):

```sh
./install.sh --prefix "$HOME/.local"
```

For the headless release, supply its build directory explicitly:

```sh
./install.sh --release _build/headless/prod/rel/geri
```

To install that release for your own account:

```sh
./install.sh --prefix "$HOME/.local" --release _build/headless/prod/rel/geri
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
