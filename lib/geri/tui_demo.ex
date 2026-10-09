if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUIDemo do
    use ExRatatui.App

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    alias ExRatatui.Widgets.{
      Block,
      List,
      Paragraph
    }

    @tick_ms 250
    @max_events 200
    @visible_files 5

    @frame_style %Style{fg: :green}
    @title_style %Style{fg: :white}

    @field_style %Style{fg: :yellow}
    @punctuation_style %Style{fg: :white}

    @server_style %Style{fg: :light_magenta}
    @port_style %Style{fg: :light_yellow}
    @filename_style %Style{fg: :light_cyan}
    @group_style %Style{fg: :light_green}
    @comment_style %Style{fg: :green}
    @from_style %Style{fg: :gray}

    @timestamp_style %Style{fg: :light_green}
    @worker_style %Style{fg: :magenta}
    @file_number_style %Style{fg: :yellow}
    @part_style %Style{fg: :light_blue}
    @message_id_style %Style{fg: :dark_gray}

    @eta_style %Style{fg: :yellow}
    @eta_value_style %Style{fg: :light_cyan}

    def run do
      {:ok, pid} =
        start_link(name: nil)

      Process.unlink(pid)

      ref =
        Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      end
    end

    @impl true
    def mount(_opts) do
      Process.send_after(
        self(),
        :tick,
        @tick_ms
      )

      files = [
        file("vacation-photos.part01.rar", 1_300_000_000),
        file("vacation-photos.part02.rar", 1_300_000_000),
        file("vacation-photos.part03.rar", 1_300_000_000),
        file("vacation-photos.part04.rar", 1_300_000_000),
        file("vacation-photos.part05.rar", 1_300_000_000),
        file("vacation-photos.part06.rar", 1_300_000_000),
        file("vacation-photos.part07.rar", 1_300_000_000),
        file("vacation-photos.part08.rar", 1_637_418_240),
        file("vacation-photos.part09.rar", 1_300_000_000),
        file("vacation-photos.part10.rar", 1_300_000_000)
      ]

      total_bytes =
        files
        |> Enum.map(& &1.total)
        |> Enum.sum()

      {:ok,
       %{
         upload_key: "KQ9f2mY7vR4pNx8cHd3sWa6tLu1jBe0G",
         started_at: System.monotonic_time(:millisecond),
         server: "news.example.com",
         port: 563,
         from: "geri@example.invalid (Geri)",
         groups: [
           "alt.binaries.boneless",
           "alt.binaries.music.mp3",
           "alt.binaries.test"
         ],
         comment: "Vacation 2026",
         connections: 12,
         checking: true,
         total_bytes: total_bytes,
         uploaded_bytes: 0,
         current_speed: 0.0,
         average_speed: 0.0,
         files: files,
         next_worker: 1,
         events: []
       }}
    end

    @impl true
    def render(
          state,
          frame
        ) do
      width =
        frame.width

      height =
        frame.height

      inner_width =
        max(
          width - 2,
          0
        )

      outer_area = %Rect{
        x: 0,
        y: 0,
        width: width,
        height: height
      }

      activity_separator_y =
        5

      total_separator_y =
        max(
          height - 3,
          activity_separator_y + 1
        )

      files_separator_y =
        max(
          total_separator_y -
            @visible_files -
            1,
          activity_separator_y + 1
        )

      activity_height =
        max(
          files_separator_y -
            activity_separator_y -
            1,
          0
        )

      widgets = [
        {
          outer_frame(
            state,
            width
          ),
          outer_area
        },
        {
          job_content(
            state,
            inner_width
          ),
          %Rect{
            x: 1,
            y: 1,
            width: inner_width,
            height: 4
          }
        },
        {
          separator(
            "activity",
            width
          ),
          %Rect{
            x: 0,
            y: activity_separator_y,
            width: width,
            height: 1
          }
        },
        {
          activity(
            state,
            inner_width
          ),
          %Rect{
            x: 1,
            y: activity_separator_y + 1,
            width: inner_width,
            height: activity_height
          }
        },
        {
          separator(
            "files",
            width
          ),
          %Rect{
            x: 0,
            y: files_separator_y,
            width: width,
            height: 1
          }
        },
        {
          total_separator(
            state,
            width
          ),
          %Rect{
            x: 0,
            y: total_separator_y,
            width: width,
            height: 1
          }
        },
        {
          total_bar(
            state,
            inner_width
          ),
          %Rect{
            x: 1,
            y: total_separator_y + 1,
            width: inner_width,
            height: 1
          }
        }
      ]

      widgets ++
        file_widgets(
          state,
          %Rect{
            x: 1,
            y: files_separator_y + 1,
            width: inner_width,
            height: @visible_files
          }
        )
    end

    @impl true
    def handle_event(
          event,
          state
        ) do
      Geri.TUI.Input.handle(
        event,
        state
      )
    end

    @impl true
    def handle_info(
          :tick,
          state
        ) do
      state =
        advance(state)

      Process.send_after(
        self(),
        :tick,
        @tick_ms
      )

      {:noreply, state}
    end

    def handle_info(
          _message,
          state
        ) do
      {:noreply, state}
    end

    defp file(
           name,
           total
         ) do
      %{
        name: name,
        total: total,
        uploaded: 0,
        checked: 0,
        total_parts: 100
      }
    end

    defp outer_frame(
           state,
           width
         ) do
      %Block{
        title:
          job_title(
            state.upload_key,
            max(
              width - 4,
              0
            )
          ),
        borders: [:all],
        border_type: :rounded,
        border_style: @frame_style
      }
    end

    defp job_title(
           upload_key,
           width
         ) do
      available =
        max(
          width - 7,
          0
        )

      key =
        fit(
          upload_key,
          available
        )

      Line.new([
        Span.new(
          " job",
          style: @title_style
        ),
        Span.new(
          ":",
          style: @punctuation_style
        ),
        Span.new(
          " ",
          style: @title_style
        ),
        Span.new(
          key,
          style: @filename_style
        ),
        Span.new(
          " ",
          style: @title_style
        )
      ])
    end

    defp job_content(
           state,
           width
         ) do
      %Paragraph{
        text: [
          job_server_from_line(
            state,
            width
          ),
          job_files_line(
            state.files,
            width
          ),
          job_groups_line(
            state.groups,
            width
          ),
          job_comment_line(
            state.comment,
            width
          )
        ]
      }
    end

    defp job_server_from_line(
           state,
           width
         ) do
      server_spans =
        server_spans(
          state.server,
          state.port
        )

      from_spans =
        from_spans(state.from)

      server_width =
        spans_width(server_spans)

      from_width =
        spans_width(from_spans)

      gap =
        width -
          server_width -
          from_width

      cond do
        gap >= 1 ->
          Line.new(
            server_spans ++
              [
                Span.new(
                  String.duplicate(
                    " ",
                    gap
                  )
                )
              ] ++
              from_spans
          )

        true ->
          available_from =
            max(
              width -
                server_width -
                1,
              0
            )

          Line.new(
            server_spans ++
              [
                Span.new(" ")
              ] ++
              truncate_spans(
                from_spans,
                available_from
              )
          )
      end
    end

    defp server_spans(
           server,
           port
         ) do
      [
        field_span("server"),
        punctuation_span(":"),
        Span.new(" "),
        Span.new(
          server,
          style: @server_style
        ),
        punctuation_span(":"),
        Span.new(
          Integer.to_string(port),
          style: @port_style
        )
      ]
    end

    defp from_spans(from) do
      [
        field_span("from"),
        punctuation_span(":"),
        Span.new(" ")
      ] ++
        styled_from_value(from)
    end

    defp styled_from_value(from) do
      from
      |> String.graphemes()
      |> Enum.chunk_by(fn character ->
        from_punctuation?(character)
      end)
      |> Enum.map(fn characters ->
        text =
          Enum.join(characters)

        style =
          if from_punctuation?(hd(characters)) do
            @punctuation_style
          else
            @from_style
          end

        Span.new(
          text,
          style: style
        )
      end)
    end

    defp from_punctuation?(character) do
      character in [
        "<",
        ">",
        "@",
        "(",
        ")"
      ]
    end

    defp job_files_line(
           files,
           width
         ) do
      spans =
        [
          field_span("files"),
          punctuation_span(":"),
          Span.new(" ")
        ] ++
          joined_value_spans(
            Enum.map(
              files,
              & &1.name
            ),
            @filename_style
          )

      Line.new(
        truncate_spans(
          spans,
          width
        )
      )
    end

    defp job_groups_line(
           groups,
           width
         ) do
      spans =
        [
          field_span("groups"),
          punctuation_span(":"),
          Span.new(" ")
        ] ++
          joined_value_spans(
            groups,
            @group_style
          )

      Line.new(
        truncate_spans(
          spans,
          width
        )
      )
    end

    defp job_comment_line(
           comment,
           width
         ) do
      spans = [
        field_span("comment"),
        punctuation_span(":"),
        Span.new(" "),
        Span.new(
          comment,
          style: @comment_style
        )
      ]

      Line.new(
        truncate_spans(
          spans,
          width
        )
      )
    end

    defp joined_value_spans(
           values,
           style
         ) do
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        prefix =
          if index == 0 do
            []
          else
            [
              Span.new(
                ", ",
                style: @punctuation_style
              )
            ]
          end

        prefix ++
          [
            Span.new(
              value,
              style: style
            )
          ]
      end)
    end

    defp field_span(name) do
      Span.new(
        name,
        style: @field_style
      )
    end

    defp punctuation_span(text) do
      Span.new(
        text,
        style: @punctuation_style
      )
    end

    defp separator(
           title,
           width
         ) do
      %Paragraph{
        text:
          separator_line(
            title,
            width
          )
      }
    end

    defp separator_line(
           _title,
           width
         )
         when width <= 1 do
      Line.new([])
    end

    defp separator_line(
           title,
           width
         ) do
      title_text =
        fit(
          " #{title} ",
          max(
            width - 2,
            0
          )
        )

      remaining =
        max(
          width -
            2 -
            String.length(title_text),
          0
        )

      Line.new([
        Span.new(
          "├",
          style: @frame_style
        ),
        Span.new(
          title_text,
          style: @title_style
        ),
        Span.new(
          String.duplicate(
            "─",
            remaining
          ),
          style: @frame_style
        ),
        Span.new(
          "┤",
          style: @frame_style
        )
      ])
    end

    defp total_separator(
           state,
           width
         ) do
      %Paragraph{
        text:
          total_separator_line(
            eta(state),
            width
          )
      }
    end

    defp total_separator_line(
           _eta,
           width
         )
         when width <= 1 do
      Line.new([])
    end

    defp total_separator_line(
           eta,
           width
         ) do
      available =
        max(
          width - 2,
          0
        )

      prefix_width =
        String.length(" total - ETA ")

      eta =
        fit(
          eta,
          max(
            available -
              prefix_width,
            0
          )
        )

      used =
        prefix_width +
          String.length(eta)

      remaining =
        max(
          available -
            used,
          0
        )

      Line.new([
        Span.new(
          "├",
          style: @frame_style
        ),
        Span.new(
          " total ",
          style: @title_style
        ),
        Span.new(
          "-",
          style: @frame_style
        ),
        Span.new(" "),
        Span.new(
          "ETA",
          style: @eta_style
        ),
        Span.new(" "),
        Span.new(
          eta,
          style: @eta_value_style
        ),
        Span.new(
          String.duplicate(
            "─",
            remaining
          ),
          style: @frame_style
        ),
        Span.new(
          "┤",
          style: @frame_style
        )
      ])
    end

    defp activity(
           state,
           width
         ) do
      items =
        Enum.map(
          state.events,
          fn event ->
            activity_line(
              event,
              state,
              width
            )
          end
        )

      %List{
        items: items,
        direction: :bottom_to_top
      }
    end

    defp activity_line(
           event,
           state,
           width
         ) do
      worker_width =
        digit_width(state.connections)

      file_width =
        digit_width(event.file_total)

      part_width =
        digit_width(event.part_total)

      worker =
        padded_number(
          event.worker,
          worker_width
        )

      file_number =
        padded_number(
          event.file_number,
          file_width
        )

      file_total =
        padded_number(
          event.file_total,
          file_width
        )

      part =
        padded_number(
          event.part,
          part_width
        )

      part_total =
        padded_number(
          event.part_total,
          part_width
        )

      core_spans = [
        Span.new(
          event.timestamp,
          style: @timestamp_style
        ),
        punctuation_span(" <"),
        Span.new(
          worker,
          style: @worker_style
        ),
        punctuation_span("> posted ["),
        Span.new(
          file_number,
          style: @file_number_style
        ),
        punctuation_span("/"),
        Span.new(
          file_total,
          style: @file_number_style
        ),
        punctuation_span("] "),
        Span.new(
          event.filename,
          style: @filename_style
        ),
        punctuation_span(" ("),
        Span.new(
          part,
          style: @part_style
        ),
        punctuation_span("/"),
        Span.new(
          part_total,
          style: @part_style
        ),
        punctuation_span(")")
      ]

      core_width =
        spans_width(core_spans)

      message_width =
        max(
          width -
            core_width -
            1,
          0
        )

      spans =
        if message_width > 0 do
          core_spans ++
            [
              Span.new(" "),
              Span.new(
                fit(
                  event.message_id,
                  message_width
                ),
                style: @message_id_style
              )
            ]
        else
          core_spans
        end

      Line.new(
        truncate_spans(
          spans,
          width
        )
      )
    end

    defp file_widgets(
           state,
           area
         ) do
      state.files
      |> visible_files()
      |> Enum.with_index()
      |> Enum.map(fn {file, row} ->
        rect = %Rect{
          x: area.x,
          y: area.y + row,
          width: area.width,
          height: 1
        }

        posted_ratio =
          ratio(
            file.uploaded,
            file.total
          )

        checked_ratio =
          if state.checking do
            ratio(
              file.checked,
              file.total
            )
          else
            nil
          end

        percent =
          format_percent(posted_ratio)

        uploaded =
          format_bytes_fixed(file.uploaded)

        total =
          format_bytes_fixed(file.total)

        fixed_width =
          String.length(percent) +
            1 +
            String.length(uploaded) +
            3 +
            String.length(total)

        filename_width =
          max(
            rect.width -
              fixed_width -
              1,
            0
          )

        filename =
          file.name
          |> fit(filename_width)
          |> pad_right(filename_width)

        label =
          filename <>
            " " <>
            percent <>
            " " <>
            uploaded <>
            " / " <>
            total

        {
          Geri.TUI.ProgressBar.new(
            rect.width,
            posted_ratio,
            label,
            checked_ratio
          ),
          rect
        }
      end)
    end

    defp visible_files(files) do
      active_index =
        active_file_index(files)

      total =
        length(files)

      max_start =
        max(
          total -
            @visible_files,
          0
        )

      start =
        if active_index < 3 do
          0
        else
          min(
            active_index - 3,
            max_start
          )
        end

      files
      |> Enum.drop(start)
      |> Enum.take(@visible_files)
    end

    defp active_file_index(files) do
      case Enum.find_index(
             files,
             fn file ->
               file.uploaded <
                 file.total
             end
           ) do
        nil ->
          max(
            length(files) - 1,
            0
          )

        index ->
          index
      end
    end

    defp total_bar(
           state,
           width
         ) do
      posted_ratio =
        ratio(
          state.uploaded_bytes,
          state.total_bytes
        )

      checked_bytes =
        state.files
        |> Enum.map(& &1.checked)
        |> Enum.sum()

      checked_ratio =
        if state.checking do
          ratio(
            checked_bytes,
            state.total_bytes
          )
        else
          nil
        end

      uploaded =
        format_bytes_fixed(state.uploaded_bytes)

      total =
        format_bytes_fixed(state.total_bytes)

      percent =
        format_percent(posted_ratio)

      current =
        format_rate_fixed(state.current_speed)

      average =
        format_rate_fixed(state.average_speed)

      label =
        uploaded <>
          " / " <>
          total <>
          " " <>
          percent <>
          " " <>
          current <>
          " now " <>
          average <>
          " avg"

      Geri.TUI.ProgressBar.new(
        width,
        posted_ratio,
        label,
        checked_ratio
      )
    end

    defp advance(state) do
      remaining =
        state.total_bytes -
          state.uploaded_bytes

      if remaining <= 0 do
        state
      else
        worker =
          state.next_worker

        file_index =
          active_file_index(state.files)

        chunk =
          min(
            remaining,
            7_000_000 +
              rem(
                (state.uploaded_bytes + 1) *
                  17,
                5_000_000
              )
          )

        files =
          add_to_files(
            state.files,
            chunk
          )

        files =
          if state.checking do
            advance_checks(files)
          else
            files
          end

        file =
          Enum.at(
            files,
            file_index
          )

        uploaded =
          state.uploaded_bytes +
            chunk

        elapsed =
          max(
            elapsed_seconds(state),
            0.001
          )

        instantaneous =
          chunk /
            (@tick_ms / 1000)

        current =
          state.current_speed *
            0.70 +
            instantaneous *
              0.30

        average =
          uploaded /
            elapsed

        part =
          part_number(
            file.uploaded,
            file.total,
            file.total_parts
          )

        event = %{
          timestamp: timestamp(),
          worker: worker,
          file_number: file_index + 1,
          file_total: length(files),
          filename: file.name,
          part: part,
          part_total: file.total_parts,
          message_id:
            fake_message_id(
              file_index + 1,
              part,
              worker
            )
        }

        events =
          [event | state.events]
          |> Enum.take(@max_events)

        %{
          state
          | uploaded_bytes: uploaded,
            files: files,
            current_speed: current,
            average_speed: average,
            next_worker:
              if(
                worker ==
                  state.connections,
                do: 1,
                else: worker + 1
              ),
            events: events
        }
      end
    end

    defp advance_checks(files) do
      Enum.map(
        files,
        fn file ->
          target =
            if file.uploaded >= file.total do
              file.total
            else
              trunc(file.uploaded * 0.72)
            end

          %{
            file
            | checked:
                min(
                  target,
                  file.uploaded
                )
          }
        end
      )
    end

    defp part_number(
           uploaded,
           total,
           total_parts
         ) do
      uploaded
      |> Kernel./(total)
      |> Kernel.*(total_parts)
      |> ceil()
      |> max(1)
      |> min(total_parts)
    end

    defp fake_message_id(
           file_number,
           part,
           worker
         ) do
      digest =
        :crypto.hash(
          :sha256,
          "#{file_number}:#{part}:#{worker}"
        )
        |> Base.url_encode64(padding: false)

      "<#{digest}@geri.invalid>"
    end

    defp add_to_files(
           files,
           bytes
         ) do
      {files, _remaining} =
        Enum.map_reduce(
          files,
          bytes,
          fn file, remaining ->
            available =
              max(
                file.total -
                  file.uploaded,
                0
              )

            add =
              min(
                available,
                remaining
              )

            {
              %{
                file
                | uploaded:
                    file.uploaded +
                      add
              },
              remaining -
                add
            }
          end
        )

      files
    end

    defp format_percent(ratio) do
      :io_lib.format(
        "~6.1f%",
        [
          ratio * 100
        ]
      )
      |> IO.iodata_to_binary()
    end

    defp format_bytes_fixed(bytes) do
      {value, unit} =
        cond do
          bytes >=
              1024 *
                1024 *
                1024 ->
            {
              bytes /
                (1024 *
                   1024 *
                   1024),
              "GiB"
            }

          bytes >=
              1024 *
                1024 ->
            {
              bytes /
                (1024 *
                   1024),
              "MiB"
            }

          bytes >= 1024 ->
            {
              bytes /
                1024,
              "KiB"
            }

          true ->
            {
              bytes * 1.0,
              "B"
            }
        end

      :io_lib.format(
        "~8.2f ~3s",
        [
          value,
          unit
        ]
      )
      |> IO.iodata_to_binary()
    end

    defp format_rate_fixed(bytes_per_second) do
      format_bytes_fixed(round(bytes_per_second)) <>
        "/s"
    end

    defp padded_number(
           number,
           width
         ) do
      number
      |> Integer.to_string()
      |> String.pad_leading(
        width,
        "0"
      )
    end

    defp digit_width(number) do
      number
      |> Integer.digits()
      |> length()
    end

    defp spans_width(spans) do
      Enum.reduce(
        spans,
        0,
        fn span, width ->
          width +
            String.length(span.content)
        end
      )
    end

    defp truncate_spans(
           _spans,
           width
         )
         when width <= 0 do
      []
    end

    defp truncate_spans(
           spans,
           width
         ) do
      {result, _remaining} =
        Enum.reduce_while(
          spans,
          {[], width},
          fn span, {result, remaining} ->
            length =
              String.length(span.content)

            cond do
              length <= remaining ->
                {:cont,
                 {
                   [
                     span
                     | result
                   ],
                   remaining -
                     length
                 }}

              remaining > 0 ->
                text =
                  fit(
                    span.content,
                    remaining
                  )

                shortened =
                  Span.new(
                    text,
                    style: span.style
                  )

                {:halt,
                 {
                   [
                     shortened
                     | result
                   ],
                   0
                 }}

              true ->
                {:halt,
                 {
                   result,
                   0
                 }}
            end
          end
        )

      Enum.reverse(result)
    end

    defp fit(
           _text,
           width
         )
         when width <= 0 do
      ""
    end

    defp fit(
           text,
           width
         ) do
      cond do
        String.length(text) <=
            width ->
          text

        width <= 3 ->
          String.slice(
            text,
            0,
            width
          )

        true ->
          String.slice(
            text,
            0,
            width - 3
          ) <>
            "..."
      end
    end

    defp pad_right(
           text,
           width
         ) do
      text <>
        String.duplicate(
          " ",
          max(
            width -
              String.length(text),
            0
          )
        )
    end

    defp ratio(
           _current,
           total
         )
         when total <= 0 do
      0.0
    end

    defp ratio(
           current,
           total
         ) do
      current
      |> Kernel./(total)
      |> min(1.0)
      |> max(0.0)
    end

    defp elapsed_seconds(state) do
      now =
        System.monotonic_time(:millisecond)

      (now -
         state.started_at) /
        1000
    end

    defp eta(state) do
      remaining =
        state.total_bytes -
          state.uploaded_bytes

      if state.average_speed > 0 do
        remaining
        |> Kernel./(state.average_speed)
        |> round()
        |> format_eta()
      else
        "--:--"
      end
    end

    defp format_eta(seconds) do
      seconds =
        max(
          seconds,
          0
        )

      days =
        div(
          seconds,
          86_400
        )

      hours =
        seconds
        |> rem(86_400)
        |> div(3600)

      minutes =
        seconds
        |> rem(3600)
        |> div(60)

      secs =
        rem(
          seconds,
          60
        )

      cond do
        days >= 100 ->
          "#{days}d"

        days >= 10 ->
          "#{days}d #{pad2(hours)}h"

        days > 0 ->
          "#{days}d #{pad2(hours)}:#{pad2(minutes)}"

        hours > 0 ->
          "#{pad2(hours)}:#{pad2(minutes)}:#{pad2(secs)}"

        true ->
          "#{pad2(minutes)}:#{pad2(secs)}"
      end
    end

    defp pad2(number) do
      number
      |> Integer.to_string()
      |> String.pad_leading(
        2,
        "0"
      )
    end

    defp timestamp do
      Time.utc_now()
      |> Time.truncate(:second)
      |> Time.to_string()
    end
  end
end
