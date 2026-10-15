if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUI do
    use ExRatatui.App

    alias ExRatatui.Layout.Rect
    alias Geri.TUI.Text
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.{Block, List, Paragraph}

    @refresh_ms 250
    @visible_files 5

    @frame_style %Style{fg: :green}
    @title_style %Style{fg: :white}
    @field_style %Style{fg: :yellow}
    @punctuation_style %Style{fg: :white}
    @server_style %Style{fg: :light_magenta}
    @port_style %Style{fg: :light_yellow}
    @server_separator_style %Style{fg: :green}
    @filename_style %Style{fg: :light_cyan}
    @group_style %Style{fg: :light_green}
    @comment_style %Style{fg: :green}
    @from_style %Style{fg: :gray}
    @timestamp_style %Style{fg: :light_green}
    @worker_style %Style{fg: :magenta}
    @checker_style %Style{fg: :light_cyan}
    @checked_style %Style{fg: :light_green}
    @repaired_style %Style{fg: :light_cyan}
    @missing_style %Style{fg: :light_yellow}
    @inconclusive_style %Style{fg: :yellow}
    @repair_failed_style %Style{fg: :light_red}
    @file_number_style %Style{fg: :yellow}
    @part_style %Style{fg: :light_blue}
    @message_id_style %Style{fg: :dark_gray}
    @eta_style %Style{fg: :yellow}
    @eta_value_style %Style{fg: :light_cyan}

    def run(job) do
      {:ok, pid} = start_link(name: nil, job: job)
      Process.unlink(pid)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end

    @impl true
    def mount(opts) do
      job = Keyword.fetch!(opts, :job)
      snapshot = Geri.JobState.snapshot(job)
      now = System.monotonic_time(:millisecond)

      Process.send_after(self(), :refresh, @refresh_ms)

      {:ok,
       %{
         job: job,
         control: Keyword.get(opts, :control),
         terminal: Keyword.get(opts, :terminal),
         mode: :running,
         snapshot: snapshot,
         sampled_at: now,
         sampled_bytes: snapshot.progress.posted_bytes,
         current_speed: 0.0,
         average_speed: 0.0
       }}
    end

    @impl true
    def render(state, frame) do
      width = frame.width
      height = frame.height
      inner_width = max(width - 2, 0)
      activity_separator_y = 5
      total_separator_y = max(height - 3, activity_separator_y + 1)

      files_separator_y =
        max(
          total_separator_y - @visible_files - 1,
          activity_separator_y + 1
        )

      activity_height =
        max(
          files_separator_y - activity_separator_y - 1,
          0
        )

      widgets = [
        {outer_frame(state.snapshot, state.mode, width), %Rect{x: 0, y: 0, width: width, height: height}},
        {job_content(state.snapshot, inner_width),
         %Rect{x: 1, y: 1, width: inner_width, height: 4}},
        {separator("activity", width),
         %Rect{x: 0, y: activity_separator_y, width: width, height: 1}},
        {activity(state.snapshot, inner_width),
         %Rect{
           x: 1,
           y: activity_separator_y + 1,
           width: inner_width,
           height: activity_height
         }},
        {separator("files", width), %Rect{x: 0, y: files_separator_y, width: width, height: 1}},
        {total_separator(state, width), %Rect{x: 0, y: total_separator_y, width: width, height: 1}},
        {total_bar(state, inner_width),
         %Rect{x: 1, y: total_separator_y + 1, width: inner_width, height: 1}}
      ]

      widgets ++
        file_widgets(
          state.snapshot,
          %Rect{
            x: 1,
            y: files_separator_y + 1,
            width: inner_width,
            height: @visible_files
          }
        )
    end

    @impl true
    def handle_event(event, state) do
      Geri.TUI.Input.handle(event, state)
    end

    @impl true
    def handle_info(:refresh, state) do
      now = System.monotonic_time(:millisecond)
      snapshot = Geri.JobState.snapshot(state.job)
      elapsed_sample = max(now - state.sampled_at, 1)
      byte_delta = max(snapshot.progress.posted_bytes - state.sampled_bytes, 0)
      instantaneous = byte_delta * 1000 / elapsed_sample
      current_speed = state.current_speed * 0.70 + instantaneous * 0.30
      elapsed_job = max(now - snapshot.progress.started_at, 1)
      average_speed = snapshot.progress.posted_bytes * 1000 / elapsed_job

      Process.send_after(self(), :refresh, @refresh_ms)

      {:noreply,
       %{
         state
         | snapshot: snapshot,
          mode: Geri.Control.mode(state.control),
           sampled_at: now,
           sampled_bytes: snapshot.progress.posted_bytes,
           current_speed: current_speed,
           average_speed: average_speed
       }}
    end

    def handle_info(_message, state) do
      {:noreply, state}
    end

    defp outer_frame(snapshot, mode, width) do
      %Block{
        title: job_title("#{mode}: #{snapshot.key}", max(width - 4, 0)),
        borders: [:all],
        border_type: :rounded,
        border_style: @frame_style
      }
    end

    defp job_title(upload_key, width) do
      available = max(width - 7, 0)
      key = fit(upload_key, available)

      Line.new([
        Span.new(" job", style: @title_style),
        punctuation_span(":"),
        Span.new(" "),
        Span.new(key, style: @filename_style),
        Span.new(" ")
      ])
    end

    defp job_content(snapshot, width) do
      %Paragraph{
        text: [
          job_server_from_line(snapshot, width),
          job_files_line(snapshot.file_names, snapshot.file_names_more, width),
          job_groups_line(snapshot.posting.newsgroups, width),
          job_comment_line(snapshot.comment, width)
        ]
      }
    end

    defp job_server_from_line(snapshot, width) do
      server_spans = server_path_spans(snapshot.servers)
      from_spans = from_spans(snapshot.from)
      server_width = spans_width(server_spans)
      from_width = spans_width(from_spans)
      gap = width - server_width - from_width

      cond do
        gap >= 1 ->
          Line.new(
            server_spans ++
              [Span.new(String.duplicate(" ", gap))] ++
              from_spans
          )

        width <= 1 ->
          Line.new(truncate_spans(server_spans, width))

        true ->
          minimum_from_width = min(from_width, max(div(width, 3), 12))
          available_server = max(width - minimum_from_width - 1, 0)
          shown_server = truncate_spans_with_ellipsis(server_spans, available_server)
          available_from = max(width - spans_width(shown_server) - 1, 0)

          Line.new(
            shown_server ++
              [Span.new(" ")] ++
              truncate_spans_with_ellipsis(from_spans, available_from)
          )
      end
    end

    defp server_path_spans(servers) do
      endpoints =
        servers
        |> Enum.with_index()
        |> Enum.flat_map(fn {server, index} ->
          separator =
            if index == 0 do
              []
            else
              [Span.new(" // ", style: @server_separator_style)]
            end

          separator ++ server_endpoint_spans(server)
        end)

      [
        field_span("server"),
        punctuation_span(":"),
        Span.new(" ")
      ] ++ endpoints
    end

    defp server_endpoint_spans(server) do
      [
        Span.new(server.host || "", style: @server_style),
        punctuation_span(":"),
        Span.new(port_text(server.port), style: @port_style)
      ]
    end

    defp port_text(nil), do: "-"
    defp port_text(port), do: Integer.to_string(port)

    defp from_spans(from) do
      [
        field_span("from"),
        punctuation_span(":"),
        Span.new(" ")
      ] ++ styled_from_value(from || "")
    end

    defp styled_from_value(from) do
      from
      |> String.graphemes()
      |> Enum.chunk_by(&from_punctuation?/1)
      |> Enum.map(fn characters ->
        text = Enum.join(characters)

        style =
          if from_punctuation?(hd(characters)) do
            @punctuation_style
          else
            @from_style
          end

        Span.new(text, style: style)
      end)
    end

    defp from_punctuation?(character) do
      character in ["<", ">", "@", "(", ")"]
    end

    # This line is deliberately built by visible width rather than truncated
    # afterward. That guarantees it ends on a complete filename or "...",
    # never on a comma or a partial separator.
    defp job_files_line(file_names, file_names_more, width) do
      prefix = [
        field_span("files"),
        punctuation_span(":"),
        Span.new(" ")
      ]

      available = max(width - spans_width(prefix), 0)

      value_spans =
        file_names
        |> fit_file_names(file_names_more, available)

      Line.new(truncate_spans(prefix ++ value_spans, width))
    end

    defp fit_file_names([], _more, _width), do: []
    defp fit_file_names(_names, _more, width) when width <= 0, do: []

    defp fit_file_names(names, more_after_snapshot, width) do
      {shown, hidden_from_names} =
        take_file_names(
          names,
          width,
          more_after_snapshot
        )

      more = hidden_from_names or more_after_snapshot

      case {shown, names, more} do
        {[], [first | _], _} ->
          [Span.new(fit(first, width), style: @filename_style)]

        _ ->
          build_file_name_spans(shown, more)
      end
    end

    defp take_file_names(names, width, more_after_snapshot) do
      total = length(names)

      {shown, _used, processed} =
        Enum.reduce_while(
          names,
          {[], 0, 0},
          fn name, {shown, used, processed} ->
            separator_width = if shown == [], do: 0, else: 2
            candidate_used = used + separator_width + Text.width(name)
            names_left = processed + 1 < total
            needs_ellipsis = names_left or more_after_snapshot
            ellipsis_width = if needs_ellipsis, do: 5, else: 0

            if candidate_used + ellipsis_width <= width do
              {:cont,
               {
                 shown ++ [name],
                 candidate_used,
                 processed + 1
               }}
            else
              {:halt, {shown, used, processed}}
            end
          end
        )

      {shown, processed < total}
    end

    defp build_file_name_spans(shown, more) do
      spans =
        shown
        |> Enum.with_index()
        |> Enum.flat_map(fn {name, index} ->
          separator =
            if index == 0 do
              []
            else
              [punctuation_span(", ")]
            end

          separator ++
            [Span.new(name, style: @filename_style)]
        end)

      if more do
        spans ++
          [
            punctuation_span(", "),
            Span.new("...", style: @filename_style)
          ]
      else
        spans
      end
    end

    defp job_groups_line(groups, width) do
      spans =
        [
          field_span("groups"),
          punctuation_span(":"),
          Span.new(" ")
        ] ++ joined_value_spans(groups, @group_style)

      Line.new(truncate_spans(spans, width))
    end

    defp job_comment_line(comment, width) do
      spans = [
        field_span("comment"),
        punctuation_span(":"),
        Span.new(" "),
        Span.new(comment || "", style: @comment_style)
      ]

      Line.new(truncate_spans(spans, width))
    end

    defp joined_value_spans(values, style) do
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        separator = if index == 0, do: [], else: [punctuation_span(", ")]
        separator ++ [Span.new(value, style: style)]
      end)
    end

    defp field_span(name), do: Span.new(name, style: @field_style)

    defp punctuation_span(text) do
      Span.new(text, style: @punctuation_style)
    end

    defp separator(title, width) do
      %Paragraph{text: separator_line(title, width)}
    end

    defp separator_line(_title, width) when width <= 1 do
      Line.new([])
    end

    defp separator_line(title, width) do
      title_text = fit(" #{title} ", max(width - 2, 0))
      remaining = max(width - 2 - Text.width(title_text), 0)

      Line.new([
        Span.new("├", style: @frame_style),
        Span.new(title_text, style: @title_style),
        Span.new(String.duplicate("─", remaining), style: @frame_style),
        Span.new("┤", style: @frame_style)
      ])
    end

    defp total_separator(state, width) do
      %Paragraph{text: total_separator_line(eta(state), width)}
    end

    defp total_separator_line(_eta, width) when width <= 1 do
      Line.new([])
    end

    defp total_separator_line(eta, width) do
      available = max(width - 2, 0)
      prefix_width = String.length(" total - ETA ")
      eta = fit(eta, max(available - prefix_width, 0))
      remaining = max(available - prefix_width - Text.width(eta), 0)

      [
        Span.new("├", style: @frame_style),
        Span.new(" total ", style: @title_style),
        Span.new("-", style: @frame_style),
        Span.new(" "),
        Span.new("ETA", style: @eta_style),
        Span.new(" "),
        Span.new(eta, style: @eta_value_style),
        Span.new(String.duplicate("─", remaining), style: @frame_style),
        Span.new("┤", style: @frame_style)
      ]
      |> truncate_spans(width, &Text.take/2)
      |> Line.new()
    end

    defp activity(snapshot, width) do
      items =
        Enum.map(snapshot.activity, fn event ->
          activity_line(event, snapshot, width)
        end)

      %List{
        items: items,
        direction: :bottom_to_top
      }
    end

    defp activity_line(%{kind: :posted} = event, snapshot, width) do
      worker_width = digit_width(snapshot.connections)

      activity_part_line(
        event,
        "<",
        padded_number(event.worker, worker_width),
        "posted",
        @worker_style,
        @punctuation_style,
        width
      )
    end

    defp activity_line(%{kind: kind} = event, snapshot, width)
         when kind in [:checked, :not_found, :missing, :inconclusive] do
      checker_width = digit_width(max(snapshot.check_connections, 1))

      {verb, verb_style} =
        case kind do
          :checked -> {"checked", @checked_style}
          :not_found -> {"not found", @missing_style}
          :missing -> {"missing", @missing_style}
          :inconclusive -> {"unknown", @inconclusive_style}
        end

      activity_part_line(
        event,
        "<C",
        padded_number(event.checker, checker_width),
        verb,
        @checker_style,
        verb_style,
        width
      )
    end

    defp activity_line(%{kind: kind} = event, _snapshot, width)
         when kind in [:repaired, :repair_failed] do
      {verb, verb_style} =
        case kind do
          :repaired -> {"repaired", @repaired_style}
          :repair_failed -> {"failed", @repair_failed_style}
        end

      activity_part_line(
        event,
        "<R",
        Integer.to_string(event.worker),
        verb,
        @checker_style,
        verb_style,
        width
      )
    end

    defp activity_line(event, snapshot, width) do
      activity_line(Map.put(event, :kind, :posted), snapshot, width)
    end

    defp activity_part_line(
           event,
           marker_prefix,
           marker_value,
           verb,
           marker_style,
           verb_style,
           width
         ) do
      file_width = digit_width(event.file_total)
      part_width = digit_width(event.part_total)

      core_spans = [
        Span.new(format_time(event.timestamp), style: @timestamp_style),
        punctuation_span(" "),
        punctuation_span(marker_prefix),
        Span.new(marker_value, style: marker_style),
        punctuation_span("> "),
        Span.new(verb, style: verb_style),
        punctuation_span(" ["),
        Span.new(padded_number(event.file_number, file_width), style: @file_number_style),
        punctuation_span("/"),
        Span.new(padded_number(event.file_total, file_width), style: @file_number_style),
        punctuation_span("] "),
        Span.new(event.filename, style: @filename_style),
        punctuation_span(" ("),
        Span.new(padded_number(event.part, part_width), style: @part_style),
        punctuation_span("/"),
        Span.new(padded_number(event.part_total, part_width), style: @part_style),
        punctuation_span(")")
      ]

      core_width = spans_width(core_spans)
      message_width = max(width - core_width - 1, 0)

      spans =
        if message_width > 0 do
          core_spans ++
            [
              Span.new(" "),
              Span.new(
                fit(event.message_id, message_width),
                style: @message_id_style
              )
            ]
        else
          core_spans
        end

      Line.new(truncate_spans(spans, width))
    end

    defp format_time(%Time{} = time) do
      time
      |> Time.truncate(:second)
      |> Time.to_string()
    end

    defp format_time(value) when is_binary(value), do: value

    defp file_widgets(snapshot, area) do
      snapshot.files
      |> Enum.sort_by(& &1.number)
      |> visible_files(snapshot.progress.active_file)
      |> Enum.with_index()
      |> Enum.map(fn {file, row} ->
        rect = %Rect{
          x: area.x,
          y: area.y + row,
          width: area.width,
          height: 1
        }

        posted_ratio = ratio(file.posted_bytes, file.total_bytes)
        checked_ratio = checked_ratio(file)
        percent = format_percent(posted_ratio)
        posted = format_bytes_fixed(file.posted_bytes)
        total = format_bytes_fixed(file.total_bytes || 0)

        fixed_width =
          String.length(percent) +
            1 +
            String.length(posted) +
            3 +
            String.length(total)

        filename_width = max(rect.width - fixed_width - 1, 0)

        filename =
          file.filename
          |> fit(filename_width)
          |> pad_right(filename_width)

        label =
          filename <>
            " " <>
            percent <>
            " " <>
            posted <>
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

    defp visible_files(files, active_number) do
      active_index =
        Enum.find_index(files, fn file ->
          file.number == active_number
        end) || 0

      max_start = max(length(files) - @visible_files, 0)

      start =
        if active_index < 3 do
          0
        else
          min(active_index - 3, max_start)
        end

      files
      |> Enum.drop(start)
      |> Enum.take(@visible_files)
    end

    defp checked_ratio(file) do
      case file.checked_bytes do
        nil -> nil
        checked -> ratio(checked, file.total_bytes)
      end
    end

    defp total_bar(state, width) do
      progress = state.snapshot.progress
      posted_ratio = ratio(progress.posted_bytes, progress.total_bytes)

      checked_ratio =
        case progress.checked_bytes do
          nil -> nil
          checked -> ratio(checked, progress.total_bytes)
        end

      posted = format_bytes_fixed(progress.posted_bytes)
      total = format_bytes_fixed(progress.total_bytes)
      percent = format_percent(posted_ratio)
      current = format_rate_fixed(state.current_speed)
      average = format_rate_fixed(state.average_speed)

      label =
        posted <>
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

    defp eta(state) do
      remaining =
        max(
          state.snapshot.progress.total_bytes -
            state.snapshot.progress.posted_bytes,
          0
        )

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
      days = div(seconds, 86_400)
      hours = seconds |> rem(86_400) |> div(3600)
      minutes = seconds |> rem(3600) |> div(60)
      secs = rem(seconds, 60)

      cond do
        days >= 100 -> "#{days}d"
        days >= 10 -> "#{days}d #{pad2(hours)}h"
        days > 0 -> "#{days}d #{pad2(hours)}:#{pad2(minutes)}"
        hours > 0 -> "#{pad2(hours)}:#{pad2(minutes)}:#{pad2(secs)}"
        true -> "#{pad2(minutes)}:#{pad2(secs)}"
      end
    end

    defp format_percent(ratio) do
      :io_lib.format("~6.1f%", [ratio * 100])
      |> IO.iodata_to_binary()
    end

    defp format_bytes_fixed(nil), do: format_bytes_fixed(0)

    defp format_bytes_fixed(bytes) do
      {value, unit} =
        cond do
          bytes >= 1024 * 1024 * 1024 ->
            {bytes / (1024 * 1024 * 1024), "GiB"}

          bytes >= 1024 * 1024 ->
            {bytes / (1024 * 1024), "MiB"}

          bytes >= 1024 ->
            {bytes / 1024, "KiB"}

          true ->
            {bytes * 1.0, "B"}
        end

      :io_lib.format("~8.2f ~3s", [value, unit])
      |> IO.iodata_to_binary()
    end

    defp format_rate_fixed(bytes_per_second) do
      format_bytes_fixed(round(bytes_per_second)) <> "/s"
    end

    defp padded_number(number, width) do
      number
      |> Integer.to_string()
      |> String.pad_leading(width, "0")
    end

    defp digit_width(number) do
      number
      |> Integer.digits()
      |> length()
    end

    defp spans_width(spans) do
      Enum.reduce(spans, 0, fn span, width ->
        width + Text.width(span.content)
      end)
    end

    defp truncate_spans(spans, width, truncate \\ &fit/2)
    defp truncate_spans(_spans, width, _truncate) when width <= 0, do: []

    defp truncate_spans(spans, width, truncate) do
      {result, _remaining} =
        Enum.reduce_while(spans, {[], width}, fn span, {result, remaining} ->
          length = Text.width(span.content)

          cond do
            length <= remaining ->
              {:cont, {[span | result], remaining - length}}

            remaining > 0 ->
              shortened =
                Span.new(
                  truncate.(span.content, remaining),
                  style: span.style
                )

              {:halt, {[shortened | result], 0}}

            true ->
              {:halt, {result, 0}}
          end
        end)

      Enum.reverse(result)
    end

    defp truncate_spans_with_ellipsis(_spans, width) when width <= 0 do
      []
    end

    defp truncate_spans_with_ellipsis(spans, width) do
      if spans_width(spans) <= width do
        spans
      else
        ellipsis_width = min(3, width)
        content_width = max(width - ellipsis_width, 0)

        truncate_spans(spans, content_width, &Text.take/2) ++
          [Span.new(String.duplicate(".", ellipsis_width), style: @server_separator_style)]
      end
    end

    defp fit(text, width), do: Text.fit(text, width)

    defp pad_right(text, width), do: Text.pad_right(text, width)

    defp ratio(_current, total) when total in [nil, 0], do: 0.0

    defp ratio(current, total) do
      current
      |> Kernel./(total)
      |> min(1.0)
      |> max(0.0)
    end

    defp pad2(number) do
      number
      |> Integer.to_string()
      |> String.pad_leading(2, "0")
    end
  end
end
