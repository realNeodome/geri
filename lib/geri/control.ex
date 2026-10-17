defmodule Geri.Control do
  @moduledoc """
  Coordinates network admission, pause, and cancellation for one upload.

  Actors are tracked by PID with a current connection, busy flag, monitor, and
  display label. Checkout marks an actor busy; connected registers its socket;
  checkin marks it idle and returns the connection it may still reuse. The
  registry can invalidate a worker's cached connection by closing it on pause.
  This process coordinates closure; it is not the transport's socket owner.

  Pause blocks new admissions and closes idle connections. Active operations
  finish before the mode changes from `:pausing` to `:paused`. `await_idle/1`
  observes registered network actors, not a frozen VM or empty work queues.

  Cancellation aborts registered queues, wakes waiters, and closes remaining
  registered sockets after a grace period. The orchestrator also uses it to
  stop peers after posting failure; cancelled mode is not itself the final
  upload result. Context contains diagnostic bindings, not a durable checkpoint.
  """

  use GenServer

  @cancel_timeout 10_000

  def start_link, do: GenServer.start_link(__MODULE__, nil)
  def pause(control), do: GenServer.call(control, :pause, :infinity)
  def resume(control), do: GenServer.call(control, :resume, :infinity)
  def cancel(control), do: GenServer.call(control, :cancel, :infinity)
  def mode(nil), do: :running
  def mode(control), do: GenServer.call(control, :mode)
  def await(nil), do: :ok
  def await(control), do: GenServer.call(control, :await, :infinity)
  def wait(nil, delay), do: Process.sleep(delay)
  # A reconnect delay must wake on cancellation and respect a pause at its
  # end. An unconditional sleep would make shutdown wait for the whole delay.
  def wait(control, delay) do
    receive do
      {:cancelled, ^control} -> {:error, :cancelled}
    after
      delay -> await(control)
    end
  end
  def await_idle(control), do: GenServer.call(control, :await_idle, :infinity)
  def checkout(control, conn, worker \\ nil)
  def checkout(nil, conn, _worker), do: {:ok, conn}
  def checkout(control, conn, worker), do: GenServer.call(control, {:checkout, conn, worker}, :infinity)
  def connected(nil, _conn), do: :ok
  def connected(control, conn), do: GenServer.call(control, {:connected, conn}, :infinity)
  def checkin(nil, conn), do: conn
  def checkin(control, conn), do: GenServer.call(control, {:checkin, conn}, :infinity)
  def release(nil), do: :ok
  def release(control), do: GenServer.call(control, :release, :infinity)
  def register_queue(control, queue), do: GenServer.call(control, {:queue, queue})
  def context(control), do: GenServer.call(control, :context)
  def put_context(control, values), do: GenServer.call(control, {:context, values})

  @impl true
  def init(nil) do
    {:ok, %{mode: :running, actors: %{}, queues: [], waiters: [], idle_waiters: [], context: %{}, timer: nil}}
  end

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}
  def handle_call(:context, _from, state), do: {:reply, state.context, state}
  def handle_call({:context, values}, _from, state), do: {:reply, :ok, %{state | context: Map.merge(state.context, values)}}

  def handle_call({:queue, queue}, _from, state) do
    if state.mode == :cancelled, do: abort_queue(queue)
    unless queue in state.queues, do: Process.monitor(queue)
    {:reply, :ok, %{state | queues: Enum.uniq([queue | state.queues])}}
  end

  def handle_call(:pause, _from, %{mode: :cancelled} = state), do: {:reply, {:error, :cancelled}, state}
  def handle_call(:pause, _from, %{mode: mode} = state) when mode in [:pausing, :paused],
    do: {:reply, :ok, state}
  def handle_call(:pause, _from, state) do
    activity(state, "preparing to pause Geri")
    {:reply, :ok, state |> Map.put(:mode, :pausing) |> close_idle() |> notify_idle()}
  end

  def handle_call(:resume, _from, %{mode: :cancelled} = state), do: {:reply, {:error, :cancelled}, state}
  def handle_call(:resume, _from, %{mode: :running} = state), do: {:reply, :ok, state}
  # Resume can overtake the last busy actor's checkin while still PAUSING.
  # Changing the mode first prevents that checkin from announcing stale PAUSED.
  def handle_call(:resume, _from, state) do
    activity(state, "Geri resumed")
    state = %{state | mode: :running}
    state = Enum.reduce(Enum.reverse(state.waiters), state, fn {from, operation}, acc ->
      {reply, acc} = enter(acc, from, operation)
      GenServer.reply(from, reply)
      acc
    end)
    {:reply, :ok, %{state | waiters: []}}
  end

  def handle_call(:cancel, _from, %{mode: :cancelled} = state), do: {:reply, :already_cancelled, state}
  def handle_call(:cancel, _from, state) do
    Enum.each(state.queues, &abort_queue/1)
    Enum.each(state.actors, fn {pid, _actor} -> send(pid, {:cancelled, self()}) end)
    Enum.each(state.waiters, fn {from, _} -> GenServer.reply(from, {:error, :cancelled}) end)
    timer = Process.send_after(self(), :cancel_timeout, @cancel_timeout)
    state = close_idle(%{state | mode: :cancelled, waiters: [], timer: timer})
    if checker = Map.get(state.context, :checker), do: send(checker, :cancel)
    {:reply, :ok, notify_idle(state)}
  end

  def handle_call(:await_idle, from, state) do
    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | idle_waiters: [from | state.idle_waiters]}}
    end
  end

  def handle_call(operation, from, state) when operation == :await or elem(operation, 0) == :checkout do
    case state.mode do
      :cancelled -> {:reply, {:error, :cancelled}, state}
      mode when mode in [:pausing, :paused] -> {:noreply, %{state | waiters: [{from, operation} | state.waiters]}}
      :running ->
        {reply, state} = enter(state, from, operation)
        {:reply, reply, state}
    end
  end

  # Checkout must precede registration, including when connect overlaps
  # cancellation. A socket acquired after cancellation must be closed too.
  def handle_call({:connected, conn}, {pid, _}, state) do
    actor = Map.fetch!(state.actors, pid)
    state = put_in(state.actors[pid], %{actor | conn: conn})
    if state.mode == :cancelled do
      Geri.NNTP.quit(conn)
      state = put_in(state.actors[pid], %{actor | conn: nil, busy: false})
      {:reply, {:error, :cancelled}, notify_idle(state)}
    else
      {:reply, :ok, state}
    end
  end

  # The caller can have lost its local socket while Control still tracks it.
  # During pause/cancel, close either reference before declaring this actor idle.
  def handle_call({:checkin, conn}, {pid, _}, state) do
    actor = Map.fetch!(state.actors, pid)
    conn = if state.mode == :running, do: conn, else: close_actor(state, %{actor | conn: conn || actor.conn})
    state = put_in(state.actors[pid], %{actor | conn: conn, busy: false})
    {:reply, conn, notify_idle(state)}
  end

  def handle_call(:release, {pid, _}, state) do
    {:reply, :ok, remove_actor(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = remove_actor(state, pid)
    state = %{state | queues: List.delete(state.queues, pid)}
    {:noreply, %{state | waiters: Enum.reject(state.waiters, fn {{waiting, _}, _} -> waiting == pid end)}}
  end

  def handle_info(:cancel_timeout, state) do
    # Interrupt a blocked receive after giving active operations time to finish.
    Enum.each(state.actors, fn {_pid, actor} -> Geri.NNTP.close(actor.conn) end)
    {:noreply, %{state | timer: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Enum.each(state.actors, fn {_pid, actor} -> close(actor.conn) end)
    :ok
  end

  defp enter(state, _from, :await), do: {:ok, state}
  # Only a first checkout trusts supplied_conn. Later checkouts use the
  # registry, which can hold nil after Control closed an idle connection.
  defp enter(state, {pid, _}, {:checkout, supplied_conn, worker}) do
    actor = Map.get_lazy(state.actors, pid, fn ->
      %{conn: supplied_conn, busy: false, monitor: Process.monitor(pid), worker: worker}
    end)
    state = put_in(state.actors[pid], %{actor | busy: true, worker: worker || actor.worker})
    {{:ok, actor.conn}, state}
  end

  defp abort_queue(queue) do
    try do
      Geri.Queue.abort(queue, :cancelled)
    catch
      :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
    end
  end

  defp close(nil), do: nil
  defp close(conn) do
    Geri.NNTP.quit(conn)
    nil
  end

  # JobState synchronously queries Control while recording posting results.
  # Activity must remain a cast to JobState to avoid a call cycle.
  defp activity(state, message, worker \\ nil) do
    if job = state.context[:job], do: Geri.JobState.activity(job, message, worker)
    :ok
  end

  defp close_actor(_state, %{conn: nil}), do: nil
  defp close_actor(state, actor) do
    close(actor.conn)
    if state.mode in [:pausing, :paused], do: activity(state, "connection closed", actor.worker)
    nil
  end

  defp close_idle(state) do
    actors = Map.new(state.actors, fn {pid, actor} ->
      {pid, if(actor.busy, do: actor, else: %{actor | conn: close_actor(state, actor)})}
    end)
    %{state | actors: actors}
  end

  defp idle?(state), do: Enum.all?(state.actors, fn {_pid, actor} -> not actor.busy end)
  # Actor exit and checkin both pass here. Announce completion once, and only
  # if a pause is still pending; resume/cancel may have superseded the request.
  defp notify_idle(state) do
    if idle?(state) do
      state =
        if state.mode == :pausing do
          activity(state, "Geri paused")
          %{state | mode: :paused}
        else
          state
        end
      Enum.each(state.idle_waiters, &GenServer.reply(&1, :ok))
      %{state | idle_waiters: []}
    else
      state
    end
  end

  defp remove_actor(state, pid) do
    case Map.pop(state.actors, pid) do
      {nil, _} -> state
      {actor, actors} ->
        Process.demonitor(actor.monitor, [:flush])
        close_actor(state, actor)
        notify_idle(%{state | actors: actors})
    end
  end
end
