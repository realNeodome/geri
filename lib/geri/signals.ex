defmodule Geri.Signals do
  @behaviour :gen_event

  def install do
    # SIGINT is bridged to SIGTERM by geri.sh while BEAM ignores SIGINT.
    handler = {__MODULE__, make_ref()}
    :ok = :gen_event.delete_handler(:erl_signal_server, :erl_signal_handler, [])
    case :gen_event.add_handler(:erl_signal_server, handler, nil) do
      :ok -> handler
      error ->
        :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
        raise "cannot install Geri signal handler: #{inspect(error)}"
    end
  end

  def uninstall(handler) do
    :gen_event.delete_handler(:erl_signal_server, handler, [])
    :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
    :ok
  end

  def attach(handler, control), do: :gen_event.call(:erl_signal_server, handler, {:attach, control})

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_call({:attach, control}, _state), do: {:ok, :ok, control}

  @impl true
  def handle_event(:sigterm, nil) do
    System.halt(130)
    {:ok, nil}
  end

  def handle_event(:sigterm, control) do
    case Geri.Control.cancel(control) do
      :already_cancelled -> System.halt(130)
      :ok -> :ok
    end
    {:ok, control}
  end

  def handle_event(signal, control) do
    :erl_signal_handler.handle_event(signal, [])
    {:ok, control}
  end

  @impl true
  def handle_info(_message, state), do: {:ok, state}
  @impl true
  def terminate(_reason, _state), do: :ok
  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}
end
