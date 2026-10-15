if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUI.Text do
    @moduledoc false

    def graphemes(text) do
      graphemes = String.graphemes(text)
      widths = ExRatatui.Native.text_widths(graphemes)
      Enum.zip(graphemes, widths)
    end

    def width(text),
      do: Enum.reduce(graphemes(text), 0, fn {_, width}, total -> total + width end)

    def take(_text, columns) when columns <= 0, do: ""

    def take(text, columns) do
      {parts, _remaining} =
        Enum.reduce_while(graphemes(text), {[], columns}, fn {grapheme, width},
                                                             {parts, remaining} ->
          if width <= remaining,
            do: {:cont, {[grapheme | parts], remaining - width}},
            else: {:halt, {parts, remaining}}
        end)

      parts |> Enum.reverse() |> IO.iodata_to_binary()
    end

    def fit(_text, columns) when columns <= 0, do: ""

    def fit(text, columns) do
      cond do
        width(text) <= columns -> text
        columns <= 3 -> take(text, columns)
        true -> take(text, columns - 3) <> "..."
      end
    end

    def pad_right(text, columns), do: text <> String.duplicate(" ", max(columns - width(text), 0))
  end
end
