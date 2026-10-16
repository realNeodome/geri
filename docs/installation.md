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

Fetching dependencies requires network access. TUI builds compile a bundled
copy of ExRatatui 0.14.0 with a small width-measurement extension. This lets
layout and truncation use the same Unicode rules as the renderer. Upstream
precompiled binaries do not include that extension.

Install a current stable Rust toolchain (including Cargo) and a C/C++ compiler.
On macOS:

```sh
brew install rust
# If the Xcode Command Line Tools are not installed:
xcode-select --install
```

On FreeBSD, `pkg install rust` supplies Rust and Cargo; the base system
provides the C/C++ compiler. On other systems, use the
[Rust installation instructions](https://www.rust-lang.org/tools/install)
and your platform's compiler tools. Check with `cargo --version` and
`cc --version`. A separate Gleam installation is not needed.

The first native build downloads Rust crates and can take several minutes.
Keep `_build` and the native build cache for subsequent updates: changing
only Geri normally recompiles Geri while Cargo reuses the native library.
Changing the bundled native source, toolchain, build profile, or target may
require rebuilding it. Installed releases need no Rust toolchain to run.
For a build without native dependencies, use the headless installation below.

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

Only one installer can modify a prefix at a time. Its private staging directory,
`PREFIX/lib/.geri-install.lock`, also acts as the installation lock. A competing
installer exits with an error instead of waiting or changing the installation.
An existing correct command symlink is reused.

If installation fails before the command link is ready, the installer restores
the previous release, or removes the new release on a first installation.
If rollback fails, it retains the lock and recovery files and prints their
location. The previous release, when present, is in `.geri-install.lock/previous`.

A forcibly terminated installer can also leave this directory behind. Before
removing it, confirm that no installer is running and inspect its contents.
If `previous` contains the old release, preserve it and restore it to `lib/geri`
after moving any failed replacement aside. Remove the lock directory only after
the installed release and any needed backup have been recovered.

To remove the system installation, after stopping jobs:

```sh
sudo rm /usr/local/bin/geri
sudo rm -r /usr/local/lib/geri
```

For a personal installation, use the corresponding `$HOME/.local` paths
without `sudo`.

## Versioning

The build obtains its version from Git and stores it in the application's
release metadata. Installed copies need neither Git nor the source checkout;
`geri --version` always reports the version of the installed build. Rebuild
and reinstall after committing changes or creating a tag to refresh it.
Git tags appear on GitHub after being pushed; they do not automatically create
a GitHub Release page.

To mark a release, first commit the intended source, then create and push its
annotated tag (choose the appropriate version):

```sh
git tag -a v0.1.0 -m "Geri 0.1.0"
git push origin v0.1.0
```

Only tags of the form `vMAJOR.MINOR.PATCH` are supported. Git describes the
nearest matching tag in history: an exact tag produces `0.1.0`, and five
commits after it produces `0.1.0+5.gabcdef0`. Tracked changes add `.dirty`,
or `+dirty` at an exact tag. Untracked files are not included in that check.
Without a matching tag, the base version in `mix.exs` is followed by the hash.
Shallow clones may lack the relevant tag or history; fetch them before building
if you want the same description as a full checkout.

Our prepared source ZIPs include a `SOURCE_VERSION` stamp so builds without
`.git` retain their source identity. GitHub-generated source downloads do not
include that generated stamp and fall back to the base version in `mix.exs`.
A valid Git checkout takes precedence over a stamp. Without Git information or
a valid stamp, builds use the base version. Changes to an extracted archive
cannot be detected by Git; its stamp identifies the archive as supplied.
