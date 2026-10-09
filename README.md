# Geri

Geri uploads binary files to NNTP servers, writes NZBs, and can check article
propagation and repair missing articles. It supports yEnc (the default),
UUEncode, and Base64.

## Screenshots

Posting files:

![Geri TUI showing posting activity and upload progress](docs/screenshots/posting.png)

Checking article propagation:

![Geri TUI showing propagation checking after posting completes](docs/screenshots/checking.png)

## Basic usage

The examples use placeholder server names. Replace them with your servers
and choose a group where posting is allowed. Credentials are read from
`~/.authinfo` or `~/.netrc`; use `--auth-file FILE` to choose another file.
For example, a `.authinfo` entry is:

```text
machine news-a.example.invalid login YOUR_USERNAME password YOUR_PASSWORD
```

Add one entry per server and restrict the file permissions with
`chmod 600 ~/.authinfo`. Options precede filenames; `--` separates the two.
These examples use TLS, the default yEnc encoding, and no TUI.

### Simple upload

Post files to server A and write an NZB:

```sh
geri upload \
  --host news-a.example.invalid --tls implicit \
  --from 'Uploader <uploader@example.invalid>' \
  --group alt.binaries.test \
  --part-size 700K --connections 8 \
  --nzb upload.nzb --no-tui -- ./*.bin
```

### ABB: upload to A, check on B, repair on B

Geri checks propagation on server B. Articles still missing after the
checking passes are posted to B. The repair server defaults to the checking
server, so `--repair-host` is unnecessary here. B must permit posting.

```sh
geri upload \
  --host news-a.example.invalid --tls implicit \
  --check-host news-b.example.invalid --check-tls implicit \
  --from 'Uploader <uploader@example.invalid>' \
  --group alt.binaries.test \
  --part-size 700K --connections 8 \
  --check-connections 2 --repair-connections 2 \
  --nzb upload-abb.nzb --no-tui -- ./*.bin
```

### ABC: upload to A, check on B, repair on C

Use a separate posting server C for repairs. Checking still takes place
on B; `--repair-host` does not change the checking server.

```sh
geri upload \
  --host news-a.example.invalid --tls implicit \
  --check-host news-b.example.invalid --check-tls implicit \
  --repair-host news-c.example.invalid --repair-tls implicit \
  --from 'Uploader <uploader@example.invalid>' \
  --group alt.binaries.test \
  --part-size 700K --connections 8 \
  --check-connections 2 --repair-connections 2 \
  --nzb upload-abc.nzb --no-tui -- ./*.bin
```

Geri prints a generated upload key. Add `--upload-key 'YOUR_SAVED_KEY'`
when retrying the same batch with unchanged files, encoding, and part size;
Geri uses STAT to skip articles already present on the posting server.
Add `--tui` after removing `--no-tui` for interactive progress and controls
in a build with TUI support. Run `geri --help` for all options.

## Upload controls

Build the release after changing the source:

```sh
MIX_ENV=prod mix release --overwrite
```

`mix release` compiles the production application as needed; separate
`mix compile` and `mix escript.build` commands are not required. If you use
an installed copy, rerun the installer after rebuilding to update it.
See [Building and installation](docs/installation.md) for the initial build
and headless installation.

Run the installed release with `geri upload ...`, or use `./geri.sh upload ...`
from the source directory. The launcher handles Ctrl-C
without the Erlang break menu. The first Ctrl-C requests cancellation;
a second Ctrl-C forces exit. Cancellation returns shell exit status 130.
Active operations can finish before shutdown; stalled connections are
closed after a ten-second grace period. A connection still being established
can take its configured connection timeout to return.

With `--tui`, press `p` to pause or resume. New posting, checking, and repair
operations wait while paused; active operations finish and idle connections
close. Queues, recovery information, and the NZB writer stay in memory.
Press `q` or Escape to hide the TUI; this does not cancel the upload.

Press backtick (`) to pause and open IEx in the same running VM. The prompt
prints the available bindings and how to return. For example:

```elixir
Geri.JobState.snapshot(job)
:sys.get_state(job)
:sys.get_state(queue)
workers
opts
resume.()
```

`job`, `queue`, `checker`, `workers`, `producer`, and `control` refer to live
processes; `opts` contains the upload options with passwords redacted.
`checker` is nil when checking is disabled. `resume.()` closes the inspection
session, restores the TUI, and resumes work. Use it instead of Ctrl-D:
Ctrl-D can leave the terminal input device at EOF and prevent later IEx
sessions from accepting input. Avoid `System.halt/0`
or terminating the IEx evaluator, since this is the upload's VM.

See the [IEx inspection guide](docs/iex-inspection.md) for examples of
examining progress, verification, queues, worker processes, recovery state
and NZB bookkeeping.

Cancellation preserves an unfinished NZB as `.part`. To retry, use the same
source files, part size, encoding, and `--upload-key`; STAT skips articles
already present on the posting server. Pause itself does not persist state
across process exits.

Run the regression tests locally:

```sh
mix test test/failure_reporting_test.exs test/upload_duplicates_test.exs test/control_test.exs test/tui_input_test.exs test/inspection_test.exs test/ui_window_test.exs
```

## Installation

See [Building and installation](docs/installation.md) for standard and
headless installation, installation prefixes, upgrades, and removal.

Build a release and install it for your own account:

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release --overwrite
./install.sh --prefix "$HOME/.local"
```

Then add `$HOME/.local/bin` to PATH and run `geri --help`.
If ExRatatui/Ratatui is unavailable on your platform, or you do not need a
terminal UI, follow the headless installation instructions in the guide.
That build excludes the terminal UI and its native dependency.

## License

Geri is licensed under the [BSD 2-Clause License](LICENSE).
Third-party dependencies retain their own licenses.
