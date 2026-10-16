if Code.ensure_loaded?(Geri.TUI) do
  defmodule Geri.PauseTUITest do
    use ExUnit.Case, async: true
    alias ExRatatui.{Event.Key, Layout.Rect, Widgets.Block, Widgets.List, Widgets.Paragraph}

    setup do
      path =
        Path.join(System.tmp_dir!(), "geri-pause-tui-#{System.unique_integer([:positive])}.bin")

      File.write!(path, "data")

      {:ok, job} =
        Geri.JobState.start_link("pause-key", [path],
          host: "a.example.com",
          from: "test@example.com",
          newsgroups: ["test"],
          connections: 16,
          check_connections: 16
        )

      snapshot = Geri.JobState.snapshot(job)
      GenServer.stop(job)
      File.rm!(path)
      %{state: %{snapshot: snapshot, mode: :running, current_speed: 0.0, average_speed: 0.0}}
    end

    test "only the two pause states gain uppercase header labels", %{state: state} do
      assert header(state) == " job: running: pause-key "
      assert header(%{state | mode: :pausing}) == " job: PAUSING: pause-key "
      assert header(%{state | mode: :paused}) == " job: PAUSED: pause-key "
    end

    test "system and worker activity renders without article fields and fits narrow rows", %{
      state: state
    } do
      for {worker, message, marker} <- [
            {nil, "preparing to pause Geri", "*"},
            {1, "connection closed", "01"},
            {"C2", "connection closed", "C02"},
            {"R3", "connection closed", "R3"},
            {nil, "Geri paused", "*"},
            {nil, "Geri resumed", "*"}
          ] do
        event = %{kind: :control, worker: worker, message: message, timestamp: ~T[12:34:56]}
        state = put_in(state.snapshot.activity, [event])
        line = activity(state, 80)
        assert text(line) == "12:34:56 <#{marker}> #{message}"

        for width <- [0, 1, 8, 12, 20, 30, 80] do
          line = activity(state, width)
          assert Geri.TUI.Text.width(text(line)) <= width

          if width > 0 do
            terminal = ExRatatui.init_test_terminal(width, 1)

            assert :ok =
                     ExRatatui.draw(terminal, [
                       {%Paragraph{text: [line]}, %Rect{x: 0, y: 0, width: width, height: 1}}
                     ])

            assert ExRatatui.get_buffer_content(terminal) == String.trim_trailing(text(line))
          end
        end
      end
    end

    for key <- ["q", "Q", "esc"], mode <- [:running, :pausing, :paused, :cancelled] do
      test "#{key} hides from #{mode} while keeping work running or cancelled" do
        {:ok, control} = Geri.Control.start_link()
        if unquote(mode) == :pausing, do: Geri.Control.checkout(control, nil, 1)
        if unquote(mode) in [:pausing, :paused], do: Geri.Control.pause(control)
        if unquote(mode) == :cancelled, do: Geri.Control.cancel(control)
        state = %{control: control}

        assert {:stop, ^state} =
                 Geri.TUI.Input.handle(
                   %Key{code: unquote(key), modifiers: [], kind: "press"},
                   state
                 )

        expected = if unquote(mode) == :cancelled, do: :cancelled, else: :running
        assert Geri.Control.mode(control) == expected
      end
    end

    test "p resumes while pause is still settling" do
      {:ok, control} = Geri.Control.start_link()
      Geri.Control.checkout(control, nil, 1)
      Geri.Control.pause(control)
      assert Geri.Control.mode(control) == :pausing
      state = %{control: control}

      assert {:noreply, ^state} =
               Geri.TUI.Input.handle(%Key{code: "p", modifiers: [], kind: "press"}, state)

      assert Geri.Control.mode(control) == :running
    end

    defp header(state) do
      [{%Block{title: title}, _} | _] = Geri.TUI.render(state, %{width: 100, height: 24})
      text(title)
    end

    defp activity(state, width) do
      [{%List{items: [line]}, _}] =
        Geri.TUI.render(state, %{width: width + 2, height: 24})
        |> Enum.filter(fn {widget, _} -> is_struct(widget, List) end)

      line
    end

    defp text(line), do: Enum.map_join(line.spans, & &1.content)
  end
end
