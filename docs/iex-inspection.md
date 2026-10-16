# Inspecting a running upload with IEx

Geri's inspection prompt runs inside the same Erlang VM as the upload. It
provides access to the actual job, queue, checking and control processes, as
well as ordinary Elixir expressions and IEx helpers.

With `--tui`, press **backtick** to pause and open IEx. To return to the TUI
and resume the upload, enter:

```elixir
resume.()
```

Use `resume.()` instead of **Ctrl-D**. Ctrl-D can leave the real terminal
input device at EOF, causing later IEx sessions to close immediately.
`resume.()` supplies EOF only to the temporary inspection session.

Console logging stays suspended during inspection; upload messages continue
to be written to `log/geri.log` relative to the upload's working directory.

**Keep the working directory unchanged while an upload is running.** IEx
`cd/1` and `File.cd/1` change the directory for the entire VM, including upload
processes. Relative input paths can then fail to open, or name a different file,
when a later file or repair is read. Relative output paths can also be affected.
Pausing does not make a directory change safe. Use `pwd()` to inspect the current
directory and absolute paths when saving diagnostics.

Example outputs below use invented values. `...` marks omitted fields or data;
those abbreviated outputs are for reading, not expressions to paste into IEx.
They show the shape of each structure, not one consistent snapshot of an upload.
Maps use `%{}`, structs such as `%Geri.Article{}` are named maps, lists use `[]`,
and tuples use `{}`. `#PID<...>` identifies a process; `MapSet.new([...])` denotes
a set. Encoded bodies and hashes are shortened to keep the examples readable.

## Contents

- [Available bindings](#available-bindings)
- [Upload overview](#upload-overview)
- [Verification and repair](#verification-and-repair)
- [Raw job state](#raw-job-state)
- [Recovery frontier](#recovery-frontier)
- [Posting queue](#posting-queue)
- [Checker state](#checker-state)
- [Worker and producer processes](#worker-and-producer-processes)
- [Pause coordinator](#pause-coordinator)
- [NZB bookkeeping](#nzb-bookkeeping)
- [General IEx tools](#general-iex-tools)
- [Saving diagnostics](#saving-diagnostics)
- [Operations that change the upload](#operations-that-change-the-upload)

## Available bindings

| Binding | Contents |
| --- | --- |
| `job` | PID holding progress, verification, recovery and NZB state |
| `queue` | Posting-queue PID |
| `checker` | Verification-coordinator PID, or `nil` when checking is disabled |
| `workers` | List of posting-worker PIDs |
| `producer` | PID preparing articles |
| `control` | Pause/cancellation-coordinator PID |
| `opts` | Upload options with passwords redacted |
| `resume` | Function returning to the TUI and resuming work |

Evaluate a binding directly to see its value:

```elixir
job
checker
workers
opts
```

A PID refers to a process; it does not contain that process's state. Use
public inspection functions or `:sys.get_state/1` to read GenServer state.

Posting workers and the producer can already have exited during the final
checks. Their PIDs remain in the bindings; this is normal. Only the top-level
posting workers are listed in `workers`, not checker or repair workers.

Pausing blocks new network operations and lets active ones finish. It does
not freeze the entire VM: bookkeeping, queued messages and timers can still
advance. Each state read is a separate snapshot, not an atomic snapshot of
every process.

## Upload overview

Start with the information used by the TUI:

```elixir
s = Geri.JobState.snapshot(job)
```

Inspect selected sections:

```elixir
s.key
s.posting
s.servers
s.progress
s.files
s.activity
```

Useful progress fields:

```elixir
s.progress.posted_bytes
s.progress.total_bytes
s.progress.checked_bytes
s.progress.active_file
```

Calculate the posting percentage:

```elixir
if s.progress.total_bytes > 0 do
  Float.round(100 * s.progress.posted_bytes / s.progress.total_bytes, 2)
end
```

An abbreviated snapshot looks like this:

```text
%{
  key: "example-upload-key",
  posting: %{host: "news-a.example.com", port: 563, tls: :implicit,
             newsgroups: ["alt.binaries.test"]},
  progress: %{active_file: 3, posted_bytes: 1433600, total_bytes: 10485760,
              checked_bytes: 716800, ...},
  files: [%{number: 3, filename: "sample.bin", total_parts: 15,
            posted_parts: 2, checked_parts: 1, ...}, ...],
  activity: [%{kind: :posted, filename: "sample.bin", part: 2, ...}, ...],
  ...
}
```

Byte counters describe source bytes, not the larger encoded articles sent over
the network. `checked_bytes` is `nil` when checking is disabled. File numbers
and part numbers start at 1. `files` is a list here; the raw `j.ui.files` field
is a map keyed by file number.

`s.files` represents the current UI window and need not contain every file.
`s` does not update automatically. Request a fresh snapshot when needed:

```elixir
s = Geri.JobState.snapshot(job)
```

## Verification and repair

Read current verification counts:

```elixir
Geri.JobState.verification(job)
```

| Field | Meaning |
| --- | --- |
| `confirmed` | Articles confirmed by checking |
| `missing` | Articles marked missing that have not subsequently been repaired |
| `repaired` | Articles successfully repaired |
| `repair_failed` | Articles whose repair failed |
| `inconclusive` | Articles whose presence could not be established |

For example, the verification result is a map of counts:

```elixir
%{confirmed: 12, missing: 1, repaired: 2, repair_failed: 0, inconclusive: 0}
```

Pending checks are not included in these five outcome counters. A successful
repair increments `repaired` and removes that part from `missing`; it does not
increment `confirmed`.

For more detail:

```elixir
details = Geri.JobState.failure_info(job)
details.upload_key
details.unresolved
details.recovery
details.nzb
```

Despite its name, `failure_info/1` is suitable for inspecting an ordinary
paused upload. It does not stop the job.

Display selected fields from the first ten unresolved articles:

```elixir
details.unresolved
|> Enum.take(10)
|> Enum.map(fn item ->
  Map.take(item, [
    :filename, :file_number, :part, :message_id, :outcome, :reason
  ])
end)
```

One selected unresolved entry might look like:

```text
%{filename: "sample.bin", file_number: 3, part: 2,
  message_id: "<example-id@1234abcd.geri>", outcome: :pending}
```

`reason` is present only when that entry has a recorded reason; `Map.take/2`
does not create absent keys. Part identity is the pair `{file_number, part}`,
so part 2 of two different files represents two different articles.

Count unresolved articles by outcome:

```elixir
Enum.frequencies_by(details.unresolved, &Map.get(&1, :outcome))
```

Find unresolved articles from file number 3:

```elixir
Enum.filter(details.unresolved, &(&1.file_number == 3))
```

Unresolved articles can be waiting for propagation checks; they are not
necessarily failures. The inspection views do not themselves perform a new
server check.

Detailed verification accounting is retained while each file is being checked
or repaired. Once that file finishes, its results are folded into upload-wide
counters and successful part keys are discarded. Unresolved article details
remain available in `Geri.JobState.failure_info(job)`.

## Raw job state

For the internal representation:

```elixir
j = :sys.get_state(job)
Map.keys(j)
j.job
j.ui
j.verification
j.recovery
```

`:sys.get_state/1` reads GenServer state without replacing it. It works for
the job, queue, checker and control coordinator. Ordinary worker tasks do
not implement this GenServer inspection interface.

The job state groups related data under these keys:

```text
%{
  job: %{key: "example-upload-key", paths: ["sample.bin", ...], ...},
  posting: %{host: "news-a.example.com", ...},
  checker: #PID<0.210.0>, control: #PID<0.205.0>,
  ui: %{active_file: 3, files: %{3 => %{filename: "sample.bin", ...}}, ...},
  verification: %{totals: %{confirmed: 12, ...}, files: %{...},
                  unresolved: %{{3, 2} => %{outcome: :pending, ...}}, ...},
  recovery: %{completed_files: 2, files: %{...}},
  nzb: %{next_file: 3, pending_files: %{...}, writer: %Geri.NZB{...}, ...}
}
```

`job` contains upload configuration, `ui` feeds the display, and `verification`
tracks propagation outcomes. `recovery` tracks posting work; `nzb` tracks output
segments. `nzb` and `checker` can be `nil` when their features are disabled.
These are ordinary nested maps, not one struct with methods.

Raw state can contain credentials, especially posting and checker options.
The provided `opts` binding is redacted; raw state is not. Select relevant
fields before sharing diagnostic output.

Internal fields may change between Geri versions. Prefer public inspection
functions for routine use, and use raw state for details they do not expose.

## Recovery frontier

Geri's upload-recovery state keeps unfinished work rather than retaining
every successfully posted part:

```elixir
details = Geri.JobState.failure_info(job)
details.recovery.files
```

Produce a compact report:

```elixir
details.recovery.files
|> Enum.sort_by(fn {number, _file} -> number end)
|> Enum.map(fn {number, file} ->
  %{
    file_number: number,
    path: file.path,
    next_part: file.next_part,
    total_parts: file.total_parts,
    unresolved_parts: map_size(file.unresolved)
  }
end)
```

For example, an unfinished recovery file can contain:

```text
%{
  file_number: 3, path: "sample.bin", total_parts: 15, next_part: 4,
  unresolved: %{2 => %{message_id: "<example-id@1234abcd.geri>",
                       source_hash: <<...>>}}
}
```

Here parts 1 through 3 have been prepared, part 2 still needs posting, and
parts 1 and 3 have completed posting. The hash records the source bytes used
for that part. `unresolved` is keyed by part number within this file; it is
separate from the upload-wide verification map keyed by `{file_number, part}`.

`next_part` is the producer frontier. It does not mean that all preceding
parts have been posted successfully. Unresolved parts can remain below it.

Inspect a particular file if it is still present:

```elixir
file = Map.get(details.recovery.files, 3)

if file do
  file.unresolved
  |> Enum.sort_by(fn {part, _article} -> part end)
  |> Enum.take(10)
end
```

Completed files can disappear from upload-recovery state. This state is
separate from propagation verification and NZB bookkeeping; an empty
recovery map does not establish that checking has finished.

## Posting queue

Read queue state and counts without consuming work:

```elixir
q = :sys.get_state(queue)

%{
  capacity: q.capacity,
  ready: :queue.len(q.ready),
  waiting_producers: :queue.len(q.producers),
  waiting_consumers: :queue.len(q.consumers),
  closed: q.closed,
  error: q.error
}
```

The internal queues use Erlang's `:queue` structure. Convert ready items to
a list, then inspect metadata rather than large encoded article bodies:

```elixir
q.ready
|> :queue.to_list()
|> Enum.take(5)
|> Enum.map(fn {part, article} ->
  %{
    filename: part.filename,
    file_number: part.file_number,
    part: part.part,
    total_parts: part.total,
    message_id: article.message_id,
    article_bytes: byte_size(article.data)
  }
end)
```

Before projection, a ready posting item has this shape:

```text
{
  %{filename: "sample.bin", file_number: 3, part: 2, total: 15,
    encoding: :yenc, offset: 716800, source_size: 716800,
    source_hash: <<...>>, body: "=ybegin ...", ...},
  %Geri.Article{message_id: "<example-id@1234abcd.geri>",
                from: "uploader@example.com", subject: "...",
                data: "From: ...\r\n..."}
}
```

`part.body` is the encoded body; `article.data` includes headers and that body.
Both can be large. `offset` is a zero-based source-file byte position, while
`part` is a one-based part number. `source_size` counts source bytes;
`byte_size(article.data)` counts encoded article bytes including headers.
The queue itself does not prescribe an item type: the repair queue uses
`{item, part, article}`, adding the check/repair metadata described below.

Workers may already hold articles while waiting at the pause gate. Those
articles do not appear in `q.ready`. A closed queue can still contain ready
items: closing means no more items will be accepted, not that all items
have been posted.

Do not call `Geri.Queue.next(queue)` for inspection. It removes a real item
and can block if the queue is empty. `push`, `close` and `abort` also change
the running upload.

## Checker state

Guard against checking being disabled:

```elixir
if checker do
  cstate = :sys.get_state(checker)

  %{
    accepting: cstate.accepting,
    pending: :gb_trees.size(cstate.queue),
    inflight: map_size(cstate.inflight),
    check_error: cstate.check_error,
    idle_workers: MapSet.size(cstate.idle),
    repairing: cstate.repairing,
    queued_repair_batches: length(cstate.repairs),
    repair_errors: cstate.repair_errors
  }
end
```

Pending checks are scheduled in an Erlang balanced tree. Show the next ten:

```elixir
if checker do
  cstate = :sys.get_state(checker)
  now = System.monotonic_time(:millisecond)

  cstate.queue
  |> :gb_trees.to_list()
  |> Enum.take(10)
  |> Enum.map(fn {{due, _sequence}, item} ->
    %{
      due_in_ms: max(due - now, 0),
      filename: item.filename,
      part: item.part,
      message_id: item.message_id,
      attempt: item.attempt,
      errors: item.errors
    }
  end)
end
```

A scheduled or inflight check carries metadata, not the encoded body:

```text
%{file_number: 3, filename: "sample.bin", path: "sample.bin",
  part: 2, part_total: 15, encoding: :yenc,
  offset: 716800, source_size: 716800, source_hash: <<...>>,
  message_id: "<example-id@1234abcd.geri>", attempt: 0, errors: 0, ...}
```

`attempt` and `errors` are retry bookkeeping. This map uses `part_total` where
the encoder's part map uses `total`. Its path, offset, source hash and encoding
metadata let repair reread and verify the original bytes, then rebuild the
article. Repairs do not keep another encoded body in this metadata.

The coordinator's collections have different keys:

| Field | Structure and contents |
| --- | --- |
| `workers` | Map from worker PID to numeric worker ID |
| `idle` | Set of worker PIDs available for assignment |
| `queue` | Balanced tree from `{due_time, sequence}` to check item |
| `inflight` | Map from worker PID to assigned check item |
| `files` | Map from file number to total parts, terminal-part set and missing-item list |
| `repairs` | List of item lists, one batch per file awaiting repair |

`repair_pid` identifies the persistent repair coordinator; it can remain alive
between batches even when `repairing` is false. Its worker PIDs are not the
posting `workers` binding.

A timer can become due while paused, but network work still waits at the
pause gate. `inflight` includes assigned work whose worker may be waiting
at that gate; it is not a count of currently open network operations.
The raw `cstate.inflight` map associates worker PIDs with their assigned articles.
`check_error` is nil normally and retains the original cause if checking stops
after a worker crash.

Checker workers are available in the raw worker map:

```elixir
if checker do
  :sys.get_state(checker).workers
end
```

Avoid `Geri.Checker.finish(checker)` during inspection: it closes the checker
to new work and waits for completion.

## Worker and producer processes

Check which processes still exist:

```elixir
Process.alive?(producer)
Enum.map(workers, fn worker -> {worker, Process.alive?(worker)} end)
```

Inspect one living posting worker:

```elixir
worker = Enum.find(workers, &Process.alive?/1)

if worker do
  Process.info(worker, [
    :status,
    :current_function,
    :current_stacktrace,
    :message_queue_len,
    :memory,
    :reductions
  ])
end
```

These fields expose scheduling status, the current call stack, mailbox size,
process memory and an execution-reduction count. Queries for exited
processes return `nil`.

For a compact report of all posting workers:

```elixir
Enum.map(workers, fn worker ->
  {worker, Process.info(worker, [
    :status, :current_function, :message_queue_len
  ])}
end)
```

Waiting in a GenServer call during pause is expected: the worker may be
waiting for permission from `control`. To inspect the producer's stack:

```elixir
Process.info(producer, :current_stacktrace)
```

## Pause coordinator

```elixir
Geri.Control.mode(control)
```

Normally the inspection prompt opens with mode `:paused`.

Inspect coordinator state:

```elixir
ctl = :sys.get_state(control)

%{
  mode: ctl.mode,
  registered_actors: map_size(ctl.actors),
  waiting_calls: length(ctl.waiters),
  registered_queues: length(ctl.queues)
}
```

A coordinator can look like this during inspection:

```text
%{mode: :paused, actors: %{#PID<0.220.0> => %{busy: false, conn: nil}},
  queues: [#PID<0.206.0>], waiters: [...], idle_waiters: [],
  context: %{job: #PID<0.204.0>, queue: #PID<0.206.0>, ...}, timer: nil}
```

`waiters` holds blocked calls waiting for permission to continue, not articles.
`actors` describes registered network workers; `queues` contains queue PIDs.
These fields therefore need not have the same counts as posting or checking
connections.

Examine registered network actors:

```elixir
Enum.map(ctl.actors, fn {pid, actor} ->
  %{
    pid: pid,
    alive: Process.alive?(pid),
    busy: actor.busy,
    has_connection: actor.conn != nil
  }
end)
```

Idle connections close during pause, so `has_connection: false` is normal.
This field indicates a stored connection object, not an independent test
of server health.

See which context fields are available:

```elixir
Geri.Control.context(control) |> Map.keys()
```

## NZB bookkeeping

The diagnostic view excludes the live writer object:

```elixir
details = Geri.JobState.failure_info(job)
details.nzb
```

If NZB output is disabled, this value is `nil`. For internal bookkeeping:

```elixir
j = :sys.get_state(job)

if j.nzb do
  Map.drop(j.nzb, [:writer])
end
```

An abbreviated `details.nzb` value:

```text
%{path: "upload.nzb", file_total: 10, next_file: 3,
  pending_files: %{
    3 => %{filename: "sample.bin", total_parts: 15,
           groups_used: MapSet.new(["alt.binaries.test"]),
           segments: %{1 => %{bytes: 728400,
                             message_id: "example-id@1234abcd.geri"}}, ...}
  }}
```

`pending_files` is keyed by file number and each `segments` map by part number.
Segments are recorded after successful posting, so gaps can exist while workers
finish out of order. Segment `bytes` counts the encoded article, not source
bytes; the stored NZB Message-ID omits the surrounding angle brackets.
`next_file` is the next file block to flush, not the next file to check.
The public diagnostic view omits `writer`; the raw state includes a
`%Geri.NZB{io: ..., path: ..., temp_path: ...}` writer while it is open.

Completed file blocks are flushed incrementally, so their per-segment data
need not remain in memory. Do not call `finalize(job)` or `abort(job)` merely
to inspect the NZB: those functions operate on the real output file.

## General IEx tools

IEx provides documentation, introspection and history helpers:

```elixir
h()
h(Enum.filter/2)
h(Process.info/2)
i(job)
i(s.progress)
exports(Geri.JobState)
exports(Geri.Control)
v(-1)
```

`h` displays documentation, `i` describes a value, `exports` lists public
functions and `v(-1)` retrieves the previous result. Geri's functions may
have limited documentation; `exports` still shows what is available.

To print a value without normal collection and string truncation:

```elixir
IO.inspect(details.recovery,
  pretty: true,
  limit: :infinity,
  printable_limit: :infinity
)
```

Use unlimited printing selectively. A complete posting queue can contain
many encoded article bodies.

Define a convenience function that reads fresh queue state on each call:

```elixir
queue_stats = fn ->
  q = :sys.get_state(queue)
  %{
    ready: :queue.len(q.ready),
    capacity: q.capacity,
    closed: q.closed,
    error: q.error
  }
end

queue_stats.()
```

Your added bindings and functions belong to that inspection session. They
are not automatically retained when you reopen IEx.

## Saving diagnostics

Save a selected diagnostic report to the current working directory:

```elixir
report = %{
  snapshot: Geri.JobState.snapshot(job),
  verification: Geri.JobState.verification(job)
}

File.write!(
  "geri-inspection.txt",
  inspect(report, pretty: true, limit: :infinity)
)
```

Check the working directory with `pwd()` without changing it. `File.write!/2`
overwrites an existing file with that name. For another output directory,
supply an absolute filename rather than using `cd/1`.

## Operations that change the upload

Most examples in this guide read state. IEx also permits arbitrary Elixir
code, including operations that change the actual upload.

Rebinding an option changes only your local variable:

```elixir
opts = Keyword.put(opts, :connections, 4)
```

This does not resize the worker pool or replace workers' existing options.
Likewise, editing a map returned by `:sys.get_state/1` does not change the
process that supplied it.

`Geri.Control.resume(control)` releases the pause gate while leaving you
in IEx. That differs from `resume.()`, which also returns to the TUI. Use
`resume.()` for the ordinary return path.

Queue mutations, job finalization, process termination, state replacement,
breakpoints and code reloads can alter or interrupt a running upload.
`System.halt/0` shuts down the entire VM. Use normal build and restart steps
when changing Geri's implementation rather than treating a live upload as
a development shell.

When finished inspecting:

```elixir
resume.()
```

## Reference documentation

- [IEx helpers](https://hexdocs.pm/iex/IEx.Helpers.html)
- [Elixir process inspection](https://hexdocs.pm/elixir/Process.html)
- [Erlang system-process inspection](https://www.erlang.org/doc/apps/stdlib/sys.html)

These references describe the general tools; Geri-specific examples above
correspond to the current implementation.
