if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUI.ProgressBar do
    alias Geri.TUI.Text
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.Paragraph

    @posted_style %Style{
      fg: :black,
      bg: :green,
      modifiers: [:bold]
    }

    @checked_style %Style{
      fg: :black,
      bg: :light_green,
      modifiers: [:bold]
    }

    @remaining_style %Style{
      fg: :light_green,
      bg: :black,
      modifiers: [:bold]
    }

    def new(
          width,
          posted_ratio,
          label,
          checked_ratio \\ nil
        ) do
      width =
        max(
          width,
          0
        )

      posted_ratio =
        clamp(posted_ratio)

      checked_ratio =
        case checked_ratio do
          nil ->
            nil

          ratio ->
            ratio
            |> clamp()
            |> min(posted_ratio)
        end

      label =
        centered_label(
          label,
          width
        )

      %Paragraph{
        text:
          progress_line(
            label,
            width,
            posted_ratio,
            checked_ratio
          )
      }
    end

    defp progress_line(
           label,
           width,
           posted_ratio,
           nil
         ) do
      posted =
        cells(
          width,
          posted_ratio
        )

      segments(
        label,
        [
          {
            0,
            posted,
            @checked_style
          },
          {
            posted,
            width,
            @remaining_style
          }
        ]
      )
    end

    defp progress_line(
           label,
           width,
           posted_ratio,
           checked_ratio
         ) do
      checked =
        cells(
          width,
          checked_ratio
        )

      posted =
        max(
          cells(
            width,
            posted_ratio
          ),
          checked
        )

      segments(
        label,
        [
          {
            0,
            checked,
            @checked_style
          },
          {
            checked,
            posted,
            @posted_style
          },
          {
            posted,
            width,
            @remaining_style
          }
        ]
      )
    end

    defp segments(
           label,
           regions
         ) do
      {graphemes, _column} =
        label
        |> Text.graphemes()
        |> Enum.map_reduce(0, fn {grapheme, width}, column ->
          # A wide glyph has one style. If it straddles a color boundary,
          # retain the style of its leading cell rather than splitting it.
          {_, _, style} =
            Enum.find(regions, fn {from, to, _} -> column >= from and column < to end) ||
              List.last(regions)

          {{grapheme, style}, column + width}
        end)

      spans =
        graphemes
        |> Enum.chunk_by(fn {_, style} -> style end)
        |> Enum.map(fn chunk ->
          {_, style} = hd(chunk)
          Span.new(Enum.map_join(chunk, fn {text, _} -> text end), style: style)
        end)

      Line.new(spans)
    end

    defp centered_label(
           label,
           width
         ) do
      label =
        fit(
          label,
          width
        )

      left =
        max(
          div(
            width -
              Text.width(label),
            2
          ),
          0
        )

      right =
        max(
          width -
            left -
            Text.width(label),
          0
        )

      String.duplicate(
        " ",
        left
      ) <>
        label <>
        String.duplicate(
          " ",
          right
        )
    end

    defp cells(
           width,
           ratio
         ) do
      width
      |> Kernel.*(ratio)
      |> round()
      |> min(width)
      |> max(0)
    end

    defp clamp(value) do
      value
      |> max(0.0)
      |> min(1.0)
    end

    defp fit(text, width), do: Text.fit(text, width)
  end
end
