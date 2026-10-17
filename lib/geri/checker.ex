defmodule Geri.Checker do
  @moduledoc """
  Schedules propagation checks and coordinates file-level repair batches.

  The coordinator owns check-worker PIDs, idle/inflight membership, a due-time
  tree, and per-file terminal-check tracking. Workers open connections lazily.
  JobState owns outcome accounting; this process decides when a file has no
  more check work and which terminally missing parts need repair.

  One repair batch runs at a time. A separate repair queue and task pool are
  created for the first batch and reused while future checks can produce work.
  An empty queue does not establish that the repair session can be destroyed.
  `finish/1` closes check admission and drains work, including final repair-pool
  shutdown; outer job cleanup subsequently stops this GenServer. The
  `repair_status` field is `:idle`, `:repairing`, or `:stopping`; pool existence
  is tracked separately by `repair_pid`. Control owns pause/cancel state.

  Check-worker crashes stop checking and classify unfinished/future checks as
  inconclusive without stopping initial posting. Established missing articles
  may still be repaired. Repair acceptance on C does not trigger a new check
  on B and must not be described as confirmed propagation there.
  """

  use GenServer

  require Logger

  @type repair_status :: :idle | :repairing | :stopping

  @typedoc """
  Body-free metadata built by JobState for checking and reconstruction.
  part_total corresponds to an encoder part's total. offset/source_size count
  source bytes; yEnc begin/end are one-based inclusive positions. Scheduling
  adds attempt/errors; verification retention can add outcome/reason.
  """
  @type item :: %{
          required(:file_number) => pos_integer(),
          required(:file_total) => pos_integer(),
          required(:file_size) => pos_integer(),
          required(:filename) => binary(),
          required(:path) => binary(),
          required(:encoding) => Geri.Article.encoding(),
          required(:subject) => binary(),
          required(:part) => pos_integer(),
          required(:part_total) => pos_integer(),
          required(:source_size) => pos_integer(),
          required(:source_hash) => Geri.Article.source_hash(),
          required(:offset) => non_neg_integer(),
          required(:message_id) => Geri.Article.message_id(),
          optional(:begin) => pos_integer() | nil,
          optional(:end) => pos_integer() | nil,
          optional(:pcrc32) => Geri.Article.crc32() | nil,
          optional(:crc32) => Geri.Article.crc32() | nil,
          optional(:attempt) => non_neg_integer(),
          optional(:errors) => non_neg_integer(),
          optional(:outcome) => :pending | Geri.Verification.outcome(),
          optional(:reason) => term()
        }

  @default_connections 2
  # Relative waits: nominal missing checks at 30, 90, and 180 seconds from
  # enqueue, plus operation/queue delays. Error retries have a separate counter.
  @check_delays [30_000, 60_000, 90_000]
  @error_retry_delay 10_000
  @error_limit 3

  def start_link(job, opts) do
    connections = Keyword.get(opts, :connections, @default_connections)
    if is_integer(connections) and connections > 0 do
      GenServer.start_link(__MODULE__, {job, opts})
    else
      {:error, :invalid_check_connections}
    end
  end

  @spec enqueue(pid(), item()) :: :ok | {:error, :checker_closed}
  def enqueue(checker, item) do
    GenServer.call(checker, {:enqueue, item}, :infinity)
  end

  @spec finish(pid()) :: :ok | {:error, term()}
  def finish(checker) do
    GenServer.call(checker, :finish, :infinity)
  end

  @impl true
  def init({job, opts}) do
    connections = Keyword.get(opts, :connections, @default_connections)

    if not is_integer(connections) or connections < 1 do
      {:stop, :invalid_check_connections}
    else
      Process.flag(:trap_exit, true)
      parent = self()

      workers =
        for id <- 1..connections, into: %{} do
          pid =
            spawn_link(fn ->
              send(parent, {:checker_ready, self(), id})
              worker_loop(parent, id, opts, nil)
            end)

          {pid, id}
        end

      state = %{
        job: job,
        opts: opts,
        connections: connections,
        workers: workers,
        idle: MapSet.new(),
        queue: :gb_trees.empty(),
        sequence: 0,
        timer: nil,
        inflight: %{},
        check_error: nil,
        accepting: true,
        finish_waiters: [],
        files: %{},
        repairs: [],
        repair_status: :idle,
        repair_pid: nil,
        repair_producer: nil,
        repair_file: nil,
        repair_errors: []
      }

      Logger.info("checking connections: #{connections}")

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:enqueue, item}, _from, %{accepting: true} = state) do
    item =
      item
      |> Map.put(:attempt, 0)
      |> Map.put(:errors, 0)

    # This tracks terminal checks, not final verification outcomes: a missing
    # part can still need repair after this per-file check record is discarded.
    file = Map.get(state.files, item.file_number, %{total: item.part_total, terminal: MapSet.new(), missing: []})

    state = put_in(state.files[item.file_number], file)
    state =
      if state.check_error do
        state |> stopped_check(item) |> maybe_start_repair()
      else
        state |> schedule(item, check_delay(0)) |> dispatch()
      end

    {:reply, :ok, state}
  end

  def handle_call({:enqueue, _item}, _from, state) do
    {:reply, {:error, :checker_closed}, state}
  end

  # The posting producer/workers have finished before normal upload shutdown
  # calls this. Stop accepting items, but keep scheduling already admitted work.
  def handle_call(:finish, from, state) do
    state = %{state | accepting: false, finish_waiters: [from | state.finish_waiters]}
    state = maybe_finish(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cancel, state) do
    {:noreply, maybe_finish(state)}
  end

  def handle_info({:checker_ready, pid, _id}, state) when is_map_key(state.workers, pid) do
    state =
      state
      |> Map.update!(:idle, &MapSet.put(&1, pid))
      |> dispatch()
      |> maybe_finish()

    {:noreply, state}
  end

  def handle_info({:checker_result, pid, id, item, result}, state) when is_map_key(state.inflight, pid) do
    state = %{
      state
      | idle: MapSet.put(state.idle, pid),
        inflight: Map.delete(state.inflight, pid)
    }

    state =
      case result do
        :cancelled ->
          state

        :present ->
          Logger.info(
            "checker #{id} confirmed #{item.message_id} " <>
              "#{item.filename} (#{item.part}/#{item.part_total})"
          )

          Geri.JobState.check_present(state.job, item, id)
          complete_check(state, item, :present)

        :missing ->
          handle_missing(state, item, id)

        {:error, reason} ->
          handle_check_error(state, item, id, reason)
      end

    state =
      state
      |> dispatch()
      |> maybe_start_repair()
      |> maybe_finish()

    {:noreply, state}
  end

  # Results already in the mailbox must not undo a stopped check's outcome.
  def handle_info({:checker_ready, _pid, _id}, state), do: {:noreply, state}
  def handle_info({:checker_result, _pid, _id, _item, _result}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) when is_map_key(state.workers, pid) do
    error = {:task_exited, :checking, {:worker, Map.fetch!(state.workers, pid)}, reason}
    Logger.error("checking stopped: #{inspect(error)}")
    state = state |> stop_checking(error) |> maybe_start_repair() |> maybe_finish()
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{repair_pid: pid} = state) do
    # Trapping worker exits also exposes an unexpected exit of the repair owner.
    handle_info({:repair_pool_finished, pid, {:error, {:task_exited, :repair, :coordinator, reason}}}, state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The producer sends this only after workers synchronously recorded every
  # result in JobState and acknowledged it. Queue emptiness alone is too early.
  # Finishing accounting does not end the pool: another file can still arrive.
  def handle_info({:repair_finished, pid, file_number, producer}, %{repair_pid: pid} = state) do
    Logger.info("repair pass completed")
    :ok = Geri.JobState.finish_verification_file(state.job, file_number)

    state = %{state | repair_status: :idle, repair_file: nil, repair_producer: producer}
    {:noreply, state |> maybe_start_repair() |> maybe_finish()}
  end

  # A cancelled pool may finish before its producer's last notification arrives.
  def handle_info({:repair_finished, _pid, _file_number, _producer}, state), do: {:noreply, state}

  def handle_info({:repair_pool_finished, pid, result}, %{repair_pid: pid} = state) do
    if state.repair_file do
      :ok = Geri.JobState.finish_verification_file(state.job, state.repair_file)
    end

    case result do
      {:error, reason} -> Logger.error("repair pass failed: #{inspect(reason)}")
      :ok -> :ok
    end

    state = %{state | repair_status: :idle, repair_pid: nil, repair_producer: nil, repair_file: nil}
    state = state |> record_repair_error(result) |> maybe_start_repair() |> maybe_finish()
    {:noreply, state}
  end

  def handle_info(:dispatch, state) do
    state =
      %{state | timer: nil}
      |> dispatch()
      |> maybe_finish()

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.repair_pid do
      Process.unlink(state.repair_pid)
      Process.exit(state.repair_pid, :shutdown)
    end

    stop_workers(state)

    :ok
  end

  defp stop_workers(state) do
    Enum.each(state.workers, fn {pid, _id} ->
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end)
  end

  # Do not restart workers and risk late results undoing classified outcomes.
  # Preserve repair state: already confirmed missing items remain repairable,
  # whereas operation failures alone are not evidence that an article is absent.
  defp stop_checking(state, error) do
    stop_workers(state)
    state = cancel_timer(state)
    pending = Map.values(state.inflight) ++ Enum.map(:gb_trees.to_list(state.queue), &elem(&1, 1))
    state = %{state | workers: %{}, idle: MapSet.new(), inflight: %{}, queue: :gb_trees.empty(), check_error: error}
    Enum.reduce(pending, state, fn item, acc -> stopped_check(acc, item) end)
  end

  defp stopped_check(state, item) do
    {:task_exited, :checking, {:worker, id}, _reason} = state.check_error
    # Keep the full crash once in the final error list, rather than copying its
    # stack trace into every article that could not be checked.
    Geri.JobState.check_inconclusive(state.job, item, id, :checker_stopped)
    complete_check(state, item, :inconclusive)
  end

  defp handle_missing(state, item, checker_id) do
    next_attempt = item.attempt + 1

    if next_attempt < length(@check_delays) do
      delay = check_delay(next_attempt)

      Geri.JobState.check_not_found(state.job, item, checker_id)

      Logger.info(
        "checker #{checker_id} not found #{item.message_id} " <>
          "#{item.filename} (#{item.part}/#{item.part_total}); " <>
          "retrying in #{div(delay, 1000)}s"
      )

      item = %{item | attempt: next_attempt, errors: 0}
      schedule(state, item, delay)
    else
      Logger.warning(
        "checker #{checker_id} could not confirm propagation of " <>
          "#{item.message_id} after #{length(@check_delays)} checks"
      )

      Geri.JobState.check_missing(state.job, item, checker_id)
      complete_check(state, item, :missing)
    end
  end

  defp handle_check_error(state, item, checker_id, reason) do
    errors = item.errors + 1

    if errors < @error_limit do
      Logger.warning(
        "checker #{checker_id} could not check #{item.message_id}: " <>
          "#{inspect(reason)}; retrying"
      )

      item = %{item | errors: errors}
      schedule(state, item, @error_retry_delay)
    else
      Logger.warning(
        "checker #{checker_id} check inconclusive for #{item.message_id}: " <>
          "#{inspect(reason)}"
      )

      Geri.JobState.check_inconclusive(state.job, item, checker_id, reason)
      complete_check(state, item, :inconclusive)
    end
  end

  defp check_delay(attempt) do
    Enum.fetch!(@check_delays, attempt)
  end

  defp schedule(state, item, delay) do
    due = System.monotonic_time(:millisecond) + delay
    # Distinguish items due in the same millisecond without comparing payloads.
    key = {due, state.sequence}

    %{
      state
      | queue: :gb_trees.enter(key, item, state.queue),
        sequence: state.sequence + 1
    }
  end

  defp dispatch(state) do
    state = cancel_timer(state)
    dispatch_ready(state)
  end

  defp dispatch_ready(state) do
    cond do
      MapSet.size(state.idle) == 0 ->
        state

      :gb_trees.is_empty(state.queue) ->
        state

      true ->
        {{due, _sequence} = key, item} = :gb_trees.smallest(state.queue)
        now = System.monotonic_time(:millisecond)

        if due <= now do
          [worker | _] = MapSet.to_list(state.idle)

          send(worker, {:check, item})

          state = %{
            state
            | idle: MapSet.delete(state.idle, worker),
              queue: :gb_trees.delete(key, state.queue),
              inflight: Map.put(state.inflight, worker, item)
          }

          dispatch_ready(state)
        else
          arm_timer(state, due - now)
        end
    end
  end

  defp arm_timer(state, delay) do
    ref = Process.send_after(self(), :dispatch, max(delay, 0))
    %{state | timer: ref}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  # Repair waits for all parts of this file to reach a terminal check result.
  # With no missing parts, result casts followed by the finish cast have one
  # sender (Checker), preserving order in JobState's mailbox without a call back.
  defp complete_check(state, item, outcome) do
    file = Map.fetch!(state.files, item.file_number)
    terminal = MapSet.put(file.terminal, item.part)
    missing = if outcome == :missing, do: [item | file.missing], else: file.missing

    if MapSet.size(terminal) == file.total do
      state = %{state | files: Map.delete(state.files, item.file_number)}

      if missing == [] do
        :ok = Geri.JobState.finish_verification_file(state.job, item.file_number)
        state
      else
        %{state | repairs: state.repairs ++ [Enum.reverse(missing)]}
      end
    else
      put_in(state.files[item.file_number], %{file | terminal: terminal, missing: missing})
    end
  end

  defp maybe_start_repair(%{repair_status: status} = state)
       when status in [:repairing, :stopping], do: state
  defp maybe_start_repair(%{repairs: []} = state), do: state

  defp maybe_start_repair(state) do
    if Geri.Control.mode(state.opts[:control]) == :cancelled do
      state
    else
      start_repair(state)
    end
  end

  # repair_pid owns the session; repair_producer receives later file batches.
  # repair_file names the current batch. Between batches the session can remain
  # alive with repair_status :idle and no active file or queued articles.
  defp start_repair(state) do
    [[first | _] = items | remaining] = state.repairs
    Logger.info("repairing #{length(items)} missing articles from #{first.filename}")

    pid =
      if state.repair_pid do
        send(state.repair_producer, {:repair, items})
        state.repair_pid
      else
        parent = self()
        article_opts = Keyword.fetch!(state.opts, :article_opts)
        repair_opts = Keyword.fetch!(state.opts, :repair_opts)

        spawn_link(fn ->
          result = Geri.repair_session(items, state.job, repair_opts, article_opts, parent)
          send(parent, {:repair_pool_finished, self(), result})
        end)
      end

    %{
      state
      | repair_status: :repairing,
        repair_pid: pid,
        repair_file: first.file_number,
        repairs: remaining
    }
  end

  defp record_repair_error(state, :ok), do: state
  defp record_repair_error(state, {:error, reason}), do: %{state | repair_errors: [reason | state.repair_errors]}

  defp maybe_finish(state) do
    cond do
      not state.accepting and Geri.Control.mode(state.opts[:control]) == :cancelled ->
        Enum.each(state.finish_waiters, &GenServer.reply(&1, {:error, :cancelled}))
        %{state | finish_waiters: []}

      not state.accepting and map_size(state.inflight) == 0 and
         :gb_trees.is_empty(state.queue) and state.repair_status == :idle and
         state.repairs == [] and map_size(state.files) == 0 ->
        if state.repair_pid do
          # All checks and file batches have finished; no producer can add work.
          # Wait for the pool to drain and close its connections before replying.
          send(state.repair_producer, :finish)
          # Remain stopping until repair_pool_finished confirms the task group
          # has drained; no new batch or finish reply may bypass that wait.
          %{state | repair_status: :stopping}
        else
          errors = List.wrap(state.check_error) ++ Enum.reverse(state.repair_errors)
          result = Geri.JobState.result(state.job, errors)
          Enum.each(state.finish_waiters, &GenServer.reply(&1, result))
          %{state | finish_waiters: []}
        end
      true ->
      state
    end
  end

  defp worker_loop(parent, id, opts, conn) do
    receive do
      {:check, item} ->
        {result, conn} = controlled_check(conn, item, opts, id)
        send(parent, {:checker_result, self(), id, item, result})
        worker_loop(parent, id, opts, conn)

      :stop ->
        Geri.NNTP.quit(conn)
        Geri.Control.release(opts[:control])
        :ok
    end
  end

  defp controlled_check(conn, item, opts, id) do
    control = opts[:control]
    case Geri.Control.checkout(control, conn, "C#{id}") do
      {:error, :cancelled} -> {:cancelled, nil}
      {:ok, conn} ->
        {result, conn} = check_item(conn, item, opts)
        conn = Geri.Control.checkin(control, conn)
        result = if Geri.Control.mode(control) == :cancelled, do: :cancelled, else: result
        {result, conn}
    end
  end

  defp check_item(conn, item, opts) do
    case ensure_connection(conn, opts) do
      {:ok, conn} ->
        case Geri.NNTP.stat(conn, item.message_id, opts) do
          :present ->
            {:present, conn}

          :missing ->
            {:missing, conn}

          {:error, reason} ->
            close_connection(conn)
            {{:error, reason}, nil}
        end

      {:error, reason} ->
        {{:error, reason}, nil}
    end
  end

  defp ensure_connection(nil, opts), do: Geri.Session.connect(opts)
  defp ensure_connection(conn, _opts), do: {:ok, conn}

  defp close_connection(nil), do: :ok
  defp close_connection(conn), do: Geri.NNTP.close(conn)
end
