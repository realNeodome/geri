defmodule ExRatatui.Widgets.Canvas.Label do
  @moduledoc """
  A text annotation to print on a `ExRatatui.Widgets.Canvas`.

  Unlike the geometric shapes, a label is rendered as plain terminal
  text on top of the canvas — it ignores the marker and is unaffected
  by canvas layers. Useful for axis labels, legends, or callouts on
  top of plotted data.

  `:x` and `:y` pin the **left edge** of the text in canvas
  coordinates.

  ## Fields

    * `:x` - x coordinate (required)
    * `:y` - y coordinate (required)
    * `:text` - string to print (required)
    * `:color` - `ExRatatui.Style.color()` for the text (required)

  ## Examples

      iex> alias ExRatatui.Widgets.Canvas.Label
      iex> %Label{x: 0.0, y: 5.0, text: "origin", color: :white}
      %ExRatatui.Widgets.Canvas.Label{
        x: 0.0,
        y: 5.0,
        text: "origin",
        color: :white
      }
  """

  @type t :: %__MODULE__{
          x: number(),
          y: number(),
          text: String.t(),
          color: ExRatatui.Style.color()
        }

  defstruct x: nil, y: nil, text: nil, color: nil
end
