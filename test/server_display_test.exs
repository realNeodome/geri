defmodule Geri.ServerDisplayTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  setup do
    path = Path.join(System.tmp_dir!(), "geri-servers-#{System.unique_integer([:positive])}.bin")
    File.write!(path, "hello")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "a simple upload shows only its posting endpoint", c do
    assert servers(c, []) == [%{host: "a.invalid", port: 563}]
  end

  test "ABB shows posting and checking without duplicating the repair endpoint", c do
    assert servers(c, check_host: "b.invalid", check_tls: :none) ==
             [%{host: "a.invalid", port: 563}, %{host: "b.invalid", port: 119}]
  end

  test "ABC shows all three endpoints in order with the effective ports", c do
    assert servers(c, check_host: "b.invalid", check_port: 1119,
                     repair_host: "c.invalid", repair_tls: :implicit) ==
             [%{host: "a.invalid", port: 563}, %{host: "b.invalid", port: 1119},
              %{host: "c.invalid", port: 563}]
  end

  test "explicit repair ports appear in the display", c do
    assert List.last(servers(c, check_host: "b.invalid", repair_host: "c.invalid", repair_port: 9119)) ==
             %{host: "c.invalid", port: 9119}
  end

  test "a repair transport change replaces B's custom port with its standard port", c do
    for tls <- [:none, :starttls] do
      assert servers(c, check_host: "b.invalid", check_port: 9118, repair_tls: tls) ==
               [
                 %{host: "a.invalid", port: 563},
                 %{host: "b.invalid", port: 9118},
                 %{host: "b.invalid", port: 119}
               ]
    end

    assert List.last(
             servers(c,
               check_host: "b.invalid",
               check_tls: :none,
               check_port: 9118,
               repair_tls: :implicit
             )
           ) ==
             %{host: "b.invalid", port: 563}
  end

  test "an explicit repair port still wins when its transport changes", c do
    assert List.last(
             servers(c,
               check_host: "b.invalid",
               check_port: 9118,
               repair_tls: :none,
               repair_port: 9119
             )
           ) ==
             %{host: "b.invalid", port: 9119}
  end

  test "the repair TLS mode selects its own default port", c do
    for {tls, port} <- [{:implicit, 563}, {:none, 119}, {:starttls, 119}] do
      assert List.last(servers(c, check_host: "b.invalid", check_port: 9118,
                               repair_host: "c.invalid", repair_tls: tls)) ==
               %{host: "c.invalid", port: port}
    end
  end

  test "a repair port on the checking host is a separate endpoint", c do
    assert servers(c, check_host: "b.invalid", check_port: 563, repair_port: 119) ==
             [%{host: "a.invalid", port: 563}, %{host: "b.invalid", port: 563},
              %{host: "b.invalid", port: 119}]
  end

  test "an explicit repair endpoint equal to the checker is shown only once", c do
    assert length(servers(c, check_host: "b.invalid", repair_host: "b.invalid")) == 2
  end

  test "repairing on the posting server preserves the A-B-A sequence", c do
    assert Enum.map(servers(c, check_host: "b.invalid", repair_host: "a.invalid"), & &1.host) ==
             ["a.invalid", "b.invalid", "a.invalid"]
  end

  test "a repair setting without checking does not imply a repair operation", c do
    assert servers(c, repair_host: "c.invalid") == [%{host: "a.invalid", port: 563}]
  end

  test "the removed server-path option is rejected and absent from help" do
    assert {:error, "invalid option " <> _} = Geri.CLI.run(["upload", "--server-path", "custom"])
    refute capture_io(fn -> Geri.CLI.run(["--help"]) end) =~ "--server-path"
  end

  defp servers(c, opts) do
    opts = Keyword.merge([host: "a.invalid", from: "test@example.invalid", newsgroups: ["test"]], opts)
    {:ok, job} = Geri.JobState.start_link("key", [c.path], opts)
    try do
      Geri.JobState.snapshot(job).servers
    after
      GenServer.stop(job)
    end
  end
end

if Code.ensure_loaded?(Geri.TUI) do
  defmodule Geri.ServerLineTest do
    use ExUnit.Case, async: true
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Paragraph

    setup do
      path = Path.join(System.tmp_dir!(), "geri-server-line-#{System.unique_integer([:positive])}.bin")
      File.write!(path, "hello")
      {:ok, job} = Geri.JobState.start_link("key", [path],
        host: "a.invalid", check_host: "b.invalid", repair_host: "c.invalid",
        from: "uploader@example.invalid", name: "Uploader", newsgroups: ["test"])
      snapshot = Geri.JobState.snapshot(job)
      GenServer.stop(job)
      File.rm!(path)
      %{snapshot: snapshot}
    end

    test "wide rows display all ABC endpoints and the complete From value", c do
      {line, text} = render_line(c.snapshot, 160)
      assert text =~ "server: a.invalid:563 // b.invalid:563 // c.invalid:563"
      assert String.ends_with?(text, "from: \"Uploader\" <uploader@example.invalid>")
      assert String.length(text) == 160
      assert draw(line, 160) == text
    end

    test "narrow rows keep both fields and mark each truncation once", c do
      snapshot = %{c.snapshot | from: String.duplicate("x", 100),
        servers: [%{host: String.duplicate("a", 100), port: 563},
                  %{host: "b.invalid", port: 563}, %{host: "c.invalid", port: 563}]}
      {line, text} = render_line(snapshot, 60)
      assert text =~ "server: "
      assert text =~ " from: "
      assert length(Regex.scan(~r/\.\.\./, text)) == 2
      refute text =~ "......"
      assert String.ends_with?(text, "...")
      assert String.length(text) <= 60
      assert draw(line, 60) == text
    end

    test "server and From text stay inside the row through resize boundaries", c do
      for width <- [0, 1, 2, 3, 6, 12, 20, 24, 40, 60, 80, 100, 160] do
        {line, text} = render_line(c.snapshot, width)
        assert String.length(text) <= width
        if width > 0, do: assert(draw(line, width) == String.trim_trailing(text))
        if width >= 24 do
          assert text =~ "server: "
          assert text =~ "from: "
        end
      end
    end

    test "a short From value stays complete while the server chain is shortened", c do
      snapshot = %{c.snapshot | from: "X"}
      {line, text} = render_line(snapshot, 40)
      assert String.ends_with?(text, "... from: X")
      assert length(Regex.scan(~r/\.\.\./, text)) == 1
      assert draw(line, 40) == text
    end

    defp render_line(snapshot, width) do
      state = %{snapshot: snapshot, mode: :running, current_speed: 0.0, average_speed: 0.0}
      {%Paragraph{text: [line | _]}, _rect} =
        Geri.TUI.render(state, %{width: width + 2, height: 24}) |> Enum.at(1)
      {line, Enum.map_join(line.spans, & &1.content)}
    end

    defp draw(line, width) do
      terminal = ExRatatui.init_test_terminal(width, 1)
      assert :ok = ExRatatui.draw(terminal,
        [{%Paragraph{text: [line]}, %Rect{x: 0, y: 0, width: width, height: 1}}])
      ExRatatui.get_buffer_content(terminal)
    end
  end
end
