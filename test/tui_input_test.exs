if Code.ensure_loaded?(Geri.TUI.Input) do
  defmodule Geri.TUIInputTest do
    use ExUnit.Case, async: false

    setup do
      {:ok, control} = Geri.Control.start_link()
      %{control: control}
    end

    test "TUI keys share the pause and cancellation control", %{control: control} do
      state = %{control: control, terminal: self()}
      pause = %ExRatatui.Event.Key{code: "p", modifiers: [], kind: "press"}
      assert {:noreply, ^state} = Geri.TUI.Input.handle(pause, state)
      assert Geri.Control.mode(control) == :paused
      assert {:noreply, ^state} = Geri.TUI.Input.handle(pause, state)
      assert Geri.Control.mode(control) == :running
      inspect_key = %ExRatatui.Event.Key{code: "`", modifiers: [], kind: "press"}
      assert {:noreply, ^state} = Geri.TUI.Input.handle(inspect_key, state)
      assert_receive :inspect
      cancel = %ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"], kind: "press"}
      assert {:noreply, ^state} = Geri.TUI.Input.handle(cancel, state)
      assert Geri.Control.mode(control) == :cancelled
    end

  end
end
