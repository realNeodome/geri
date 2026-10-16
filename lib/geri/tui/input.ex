if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUI.Input do
    def handle(%ExRatatui.Event.Key{kind: "press", code: "c", modifiers: modifiers}, %{control: control} = state)
        when not is_nil(control) do
      if "ctrl" in modifiers do
        case Geri.Control.cancel(control) do
          :already_cancelled -> System.halt(130)
          :ok -> :ok
        end
      end
      {:noreply, state}
    end

    def handle(%ExRatatui.Event.Key{kind: "press", code: "p", modifiers: []}, %{control: control} = state)
        when not is_nil(control) do
      case Geri.Control.mode(control) do
        :running -> Geri.Control.pause(control)
        mode when mode in [:pausing, :paused] -> Geri.Control.resume(control)
        :cancelled -> :ok
      end
      {:noreply, state}
    end

    def handle(%ExRatatui.Event.Key{kind: "press", code: "`"}, %{terminal: terminal} = state)
        when not is_nil(terminal) do
      send(terminal, :inspect)
      {:noreply, state}
    end

    def handle(
          %ExRatatui.Event.Key{
            kind: "press",
            code: code
          },
          state
        )
        when code in [
               "q",
               "Q",
               "esc"
             ] do
      # Once hidden, the normal keyboard resume controls are no longer available.
      if control = state[:control], do: Geri.Control.resume(control)
      {:stop, state}
    end

    def handle(
          _event,
          state
        ) do
      {:noreply, state}
    end
  end
end
