defmodule Geri.Checker do
  use GenServer

  require Logger

  @default_connections 2
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

  def enqueue(checker, item) do
    GenServer.call(checker, {:enqueue, item}, :infinity)
  end

  def finish(checker) do
    GenServer.call(checker, :finish, :infinity)
  end

  @impl true
  def init({job, opts}) do
    connections = Keyword.get(opts, :connections, @default_connections)

    if not is_integer(connections) or connections < 1 do
      {:stop, :invalid_check_connections}
    else
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
        inflight: 0,
        accepting: true,
        finish_waiters: [],
        files: %{},
        repairs: [],
        repairing: false,
        repair_pid: nil,
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

    file = Map.get(state.files, item.file_number, %{total: item.part_total, terminal: MapSet.new(), missing: []})

    state =
      state
      |> put_in([:files, item.file_number], file)
      |> schedule(item, check_delay(0))
      |> dispatch()

    {:reply, :ok, state}
  end

  def handle_call({:enqueue, _item}, _from, state) do
    {:reply, {:error, :checker_closed}, state}
  end

  def handle_call(:finish, from, state) do
    state = %{state | accepting: false, finish_waiters: [from | state.finish_waiters]}
    state = maybe_finish(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cancel, state) do
    {:noreply, maybe_finish(state)}
  end

  def handle_info({:checker_ready, pid, _id}, state) do
    state =
      state
      |> Map.update!(:idle, &MapSet.put(&1, pid))
      |> dispatch()
      |> maybe_finish()

    {:noreply, state}
  end

  def handle_info({:checker_result, pid, id, item, result}, state) do
    state = %{
      state
      | idle: MapSet.put(state.idle, pid),
        inflight: max(state.inflight - 1, 0)
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

  def handle_info({:repair_finished, result}, state) do
    case result do
      :ok ->
        Logger.info("repair pass completed")

      {:error, reason} ->
        Logger.error("repair pass failed: #{inspect(reason)}")
    end

    state =
      state
      |> Map.put(:repairing, false)
      |> Map.put(:repair_pid, nil)
      |> record_repair_error(result)
      |> maybe_start_repair()
      |> maybe_finish()

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

    Enum.each(state.workers, fn {pid, _id} ->
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end)

    :ok
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
              inflight: state.inflight + 1
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

  defp complete_check(state, item, outcome) do
    file = Map.fetch!(state.files, item.file_number)
    terminal = MapSet.put(file.terminal, item.part)
    missing = if outcome == :missing, do: [item | file.missing], else: file.missing

    if MapSet.size(terminal) == file.total do
      state = %{state | files: Map.delete(state.files, item.file_number)}

      if missing == [] do
        state
      else
        %{state | repairs: state.repairs ++ [Enum.reverse(missing)]}
      end
    else
      put_in(state.files[item.file_number], %{file | terminal: terminal, missing: missing})
    end
  end

  defp maybe_start_repair(%{repairing: true} = state), do: state
  defp maybe_start_repair(%{repairs: []} = state), do: state

  defp maybe_start_repair(state) do
    if Geri.Control.mode(state.opts[:control]) == :cancelled do
      state
    else
      start_repair(state)
    end
  end

  defp start_repair(state) do
    [items | remaining] = state.repairs
    parent = self()
    article_opts = Keyword.fetch!(state.opts, :article_opts)
    repair_opts = Keyword.fetch!(state.opts, :repair_opts)

    Logger.info("repairing #{length(items)} missing articles from #{hd(items).filename}")

    pid = spawn_link(fn ->
      result = Geri.repair(items, state.job, repair_opts, article_opts)
      send(parent, {:repair_finished, result})
    end)

    %{state | repairing: true, repair_pid: pid, repairs: remaining}
  end

  defp record_repair_error(state, :ok), do: state
  defp record_repair_error(state, {:error, reason}), do: %{state | repair_errors: [reason | state.repair_errors]}

  defp maybe_finish(state) do
    cond do
      not state.accepting and Geri.Control.mode(state.opts[:control]) == :cancelled ->
        Enum.each(state.finish_waiters, &GenServer.reply(&1, {:error, :cancelled}))
        %{state | finish_waiters: []}

      not state.accepting and state.inflight == 0 and
         :gb_trees.is_empty(state.queue) and not state.repairing and
         state.repairs == [] and map_size(state.files) == 0 ->
      result = Geri.JobState.result(state.job, Enum.reverse(state.repair_errors))
      Enum.each(state.finish_waiters, &GenServer.reply(&1, result))
      %{state | finish_waiters: []}
      true ->
      state
    end
  end

  defp worker_loop(parent, id, opts, conn) do
    receive do
      {:check, item} ->
        {result, conn} = controlled_check(conn, item, opts)
        send(parent, {:checker_result, self(), id, item, result})
        worker_loop(parent, id, opts, conn)

      :stop ->
        Geri.NNTP.quit(conn)
        Geri.Control.release(opts[:control])
        :ok
    end
  end

  defp controlled_check(conn, item, opts) do
    control = opts[:control]
    case Geri.Control.checkout(control, conn) do
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

  defp ensure_connection(nil, opts), do: connect(opts)
  defp ensure_connection(conn, _opts), do: {:ok, conn}

  defp connect(opts) do
    with {:ok, conn} <- Geri.NNTP.connect(opts),
         :ok <- Geri.Control.connected(opts[:control], conn) do
      case Geri.NNTP.authenticate(
             conn,
             Keyword.get(opts, :username),
             Keyword.get(opts, :password),
             opts
           ) do
        :ok ->
          {:ok, conn}

        {:error, reason} ->
          Geri.NNTP.close(conn)
          {:error, reason}
      end
    end
  end

  defp close_connection(nil), do: :ok
  defp close_connection(conn), do: Geri.NNTP.close(conn)
end
