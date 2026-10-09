if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUI.ProgressBar do
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
      spans =
        regions
        |> Enum.flat_map(fn {from, to, style} ->
          length =
            max(
              to - from,
              0
            )

          if length == 0 do
            []
          else
            [
              Span.new(
                String.slice(
                  label,
                  from,
                  length
                ),
                style: style
              )
            ]
          end
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
              String.length(label),
            2
          ),
          0
        )

      right =
        max(
          width -
            left -
            String.length(label),
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
        String.length(text) <= width ->
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
          ) <> "..."
      end
    end
  end
end
