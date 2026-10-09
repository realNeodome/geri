if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.Terminal do
    use GenServer

    def start_link(job, control) do
      case GenServer.start(__MODULE__, {job, control}) do
        {:ok, pid} ->
          Process.link(pid)
          {:ok, pid}
        error -> error
      end
    end

    @impl true
    def init({job, control}) do
      Geri.Control.put_context(control, %{terminal: self()})
      state = %{job: job, control: control, tui: nil, logger: nil, inspection: nil}
      case open_tui(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_info(:inspect, %{inspection: nil} = state) do
      case Geri.Control.pause(state.control) do
        :ok ->
          state = close_tui(state, false)
          parent = self()
          {pid, ref} = spawn_monitor(fn ->
            Geri.Inspection.run(state.control)
            send(parent, :inspection_done)
          end)
          {:noreply, %{state | inspection: {pid, ref}}}
        {:error, :cancelled} -> {:noreply, state}
      end
    end

    def handle_info(:inspection_done, state) do
      {_pid, ref} = state.inspection
      Process.demonitor(ref, [:flush])
      state = %{state | inspection: nil}
      if Geri.Control.mode(state.control) == :cancelled do
        {:noreply, state}
      else
        case open_tui(state) do
          {:ok, state} ->
            Geri.Control.resume(state.control)
            {:noreply, state}
          {:error, reason} ->
            Geri.Control.cancel(state.control)
            {:stop, reason, state}
        end
      end
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{inspection: {_pid2, ref}} = state) do
      require Logger
      Logger.error("IEx inspection ended unexpectedly: #{inspect(reason)}; upload remains paused")
      state = %{state | inspection: nil}
      case open_tui(state) do
        {:ok, state} -> {:noreply, state}
        {:error, error} ->
          Geri.Control.cancel(state.control)
          {:stop, error, state}
      end
    end

    def handle_info({:DOWN, _ref, :process, pid, _reason}, %{tui: pid} = state) do
      Geri.TUI.Logger.restore_console(state.logger)
      {:noreply, %{state | tui: nil, logger: nil}}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state) do
      close_tui(state)
      if state.inspection do
        {pid, _ref} = state.inspection
        Process.exit(pid, :shutdown)
      end
      :ok
    end

    defp open_tui(state) do
      with {:ok, logger} <- Geri.TUI.Logger.suspend_console() do
        # Inspection keeps the console suspended. Preserve its original
        # configuration when reopening the TUI finds no console handler.
        logger = state.logger || logger
        case Geri.TUI.start_link(name: nil, job: state.job, control: state.control, terminal: self()) do
          {:ok, pid} ->
            Process.unlink(pid)
            Process.monitor(pid)
            {:ok, %{state | tui: pid, logger: logger}}
          {:error, reason} ->
            Geri.TUI.Logger.restore_console(logger)
            {:error, {:tui_start_failed, reason}}
        end
      end
    end

    defp close_tui(state, restore_console \\ true) do
      if state.tui && Process.alive?(state.tui), do: GenServer.stop(state.tui, :normal, :infinity)
      if restore_console do
        Geri.TUI.Logger.restore_console(state.logger)
        %{state | tui: nil, logger: nil}
      else
        %{state | tui: nil}
      end
    end
  end
end
