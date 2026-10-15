if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUIUnicodeTest do
    use ExUnit.Case, async: true
    alias Geri.TUI.{ProgressBar, Text}
    alias ExRatatui.{CellSession, Style}
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.Paragraph

    @samples [
      "ASCII",
      "café",
      "é",
      "日本語",
      "中文",
      "한국어",
      "가",
      "😀",
      "👩‍👩‍👧‍👦",
      "🇺🇸",
      "❤️",
      "👍🏽",
      "1️⃣",
      "🏳️‍🌈",
      "क्षि",
      "நி",
      "தமிழ்",
      "हिन्दी",
      "मराठी",
      "नेपाली",
      "กำ",
      "கா",
      "क्ष",
      "لا",
      "العَرَبِيَّة",
      "\t",
      "\u200B",
      "\u302A",
      "\u0600",
      "a\u200B"
    ]

    test "native measurements match the renderer across scripts, emoji and controls" do
      for text <- @samples do
        assert Text.width(text) == rendered_width(Line.new([Span.new(text)])), inspect(text)
      end

      assert Text.width("क्षि") == 3
      assert Text.width("நி") == 2
      assert Text.width("👩‍👩‍👧‍👦") == 2
    end

    test "truncation fits cells without splitting graphemes and padding fills the budget" do
      assert Text.take("日", 1) == ""
      assert Text.take("日a", 2) == "日"
      assert Text.take("éx", 1) == "é"
      assert Text.take("👩‍👩‍👧‍👦x", 1) == ""
      assert Text.take("👩‍👩‍👧‍👦x", 2) == "👩‍👩‍👧‍👦"
      assert Text.take("क्षि", 2) == ""
      assert Text.fit("日本語", 5) == "日..."

      for text <- @samples, columns <- 0..20 do
        fitted = Text.fit(text, columns)
        width = rendered_width(Line.new([Span.new(fitted)]))
        assert width <= columns, inspect({text, columns, fitted, width})
        padded = Text.pad_right(fitted, columns)
        assert rendered_width(Line.new([Span.new(padded)])) == columns
        assert String.valid?(fitted)
      end
    end

    test "progress bars preserve wide glyphs across color boundaries" do
      %Paragraph{text: line} = ProgressBar.new(6, 0.5, "日本語")
      assert line_text(line) == "日本語"
      assert Enum.map(line.spans, & &1.content) == ["日本", "語"]
      assert rendered_width(line) == 6
      cells = draw(line, 6)
      assert Enum.find(cells, &(&1.col == 2)).bg == :light_green
      assert Enum.find(cells, &(&1.col == 4)).bg == :black

      for text <- @samples, columns <- 0..20, checked <- [nil, 0.25] do
        %Paragraph{text: line} = ProgressBar.new(columns, 0.6, text, checked)
        assert rendered_width(line) == columns, inspect({text, columns, checked})
        assert line_text(line) == Text.pad_right(line_text(line), columns)
      end
    end

    test "server From, filenames, comments and file bars respect narrow rectangles" do
      dir = Path.join(System.tmp_dir!(), "geri-tui-unicode-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "日本語-क्षि-👩‍👩‍👧‍👦.bin")
      File.write!(path, "hello")

      {:ok, job} =
        Geri.JobState.start_link("key", [path],
          host: "a.example.com",
          check_host: "b.example.com",
          repair_host: "c.example.com",
          from: "geri@example.com",
          name: "Géri 日本語 हिन्दी",
          comment: "日本語 👩‍👩‍👧‍👦 हिन्दी",
          newsgroups: ["test"]
        )

      snapshot = Geri.JobState.snapshot(job)
      GenServer.stop(job)
      File.rm_rf!(dir)

      snapshot = %{
        snapshot
        | files: [
            %{
              number: 1,
              filename: Path.basename(path),
              posted_bytes: 5,
              total_bytes: 10,
              checked_bytes: 2
            }
          ]
      }

      event = %{
        kind: :posted,
        timestamp: ~T[12:00:00],
        worker: 1,
        file_number: 1,
        file_total: 1,
        filename: Path.basename(path),
        part: 1,
        part_total: 2,
        message_id: "<test@example.com>"
      }

      snapshot = %{snapshot | activity: [event]}
      state = %{snapshot: snapshot, mode: :running, current_speed: 0.0, average_speed: 0.0}

      for inner <- Enum.to_list(0..15) ++ Enum.to_list(20..160//10) do
        widgets = Geri.TUI.render(state, %{width: inner + 2, height: 24})

        for {%Paragraph{text: text}, rect} <- widgets do
          lines = if is_list(text), do: text, else: [text]

          for %Line{} = line <- lines do
            assert rendered_width(line) <= rect.width, inspect({inner, line_text(line)})
          end
        end

        for {%ExRatatui.Widgets.List{items: items}, rect} <- widgets, %Line{} = line <- items do
          assert rendered_width(line) <= rect.width, inspect({inner, line_text(line)})
        end

        {%Paragraph{text: [server_line | _]}, _} = Enum.at(widgets, 1)

        if inner >= 140 do
          assert line_text(server_line) =~ "c.example.com:563"
          assert line_text(server_line) =~ "Géri 日本語 हिन्दी"
        end
      end
    end

    defp line_text(line), do: Enum.map_join(line.spans, & &1.content)

    defp rendered_width(line) do
      marker = Span.new("|", style: %Style{fg: :red})
      cells = draw(%{line | spans: line.spans ++ [marker]}, 256)
      cell = Enum.find(cells, &(&1.symbol == "|" and &1.fg == :red))
      assert cell != nil
      cell.col
    end

    defp draw(line, columns) do
      session = CellSession.new(max(columns, 1), 1)

      try do
        :ok =
          CellSession.draw(session, [
            {%Paragraph{text: [line]}, %Rect{x: 0, y: 0, width: columns, height: 1}}
          ])

        CellSession.take_cells(session).cells
      after
        CellSession.close(session)
      end
    end
  end
end
