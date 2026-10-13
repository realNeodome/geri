defmodule Geri.Control do
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
  def wait(control, delay) do
    receive do
      {:cancelled, ^control} -> {:error, :cancelled}
    after
      delay -> await(control)
    end
  end
  def await_idle(control), do: GenServer.call(control, :await_idle, :infinity)
  def checkout(nil, conn), do: {:ok, conn}
  def checkout(control, conn), do: GenServer.call(control, {:checkout, conn}, :infinity)
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
    {:reply, :ok, %{state | queues: [queue | state.queues]}}
  end

  def handle_call(:pause, _from, %{mode: :cancelled} = state), do: {:reply, {:error, :cancelled}, state}
  def handle_call(:pause, _from, state) do
    {:reply, :ok, close_idle(%{state | mode: :paused})}
  end

  def handle_call(:resume, _from, %{mode: :cancelled} = state), do: {:reply, {:error, :cancelled}, state}
  def handle_call(:resume, _from, state) do
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
      :paused -> {:noreply, %{state | waiters: [{from, operation} | state.waiters]}}
      :running ->
        {reply, state} = enter(state, from, operation)
        {:reply, reply, state}
    end
  end

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

  def handle_call({:checkin, conn}, {pid, _}, state) do
    actor = Map.fetch!(state.actors, pid)
    conn = if state.mode == :running, do: conn, else: close(conn)
    state = put_in(state.actors[pid], %{actor | conn: conn, busy: false})
    {:reply, conn, notify_idle(state)}
  end

  def handle_call(:release, {pid, _}, state) do
    {:reply, :ok, remove_actor(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = remove_actor(state, pid)
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
  defp enter(state, {pid, _}, {:checkout, supplied_conn}) do
    actor = Map.get_lazy(state.actors, pid, fn ->
      %{conn: supplied_conn, busy: false, monitor: Process.monitor(pid)}
    end)
    state = put_in(state.actors[pid], %{actor | busy: true})
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

  defp close_idle(state) do
    actors = Map.new(state.actors, fn {pid, actor} ->
      {pid, if(actor.busy, do: actor, else: %{actor | conn: close(actor.conn)})}
    end)
    %{state | actors: actors}
  end

  defp idle?(state), do: Enum.all?(state.actors, fn {_pid, actor} -> not actor.busy end)
  defp notify_idle(state) do
    if idle?(state) do
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
        close(actor.conn)
        notify_idle(%{state | actors: actors})
    end
  end
end
