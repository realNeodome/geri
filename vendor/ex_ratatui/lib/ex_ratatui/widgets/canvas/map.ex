defmodule ExRatatui.Widgets.Canvas.Map do
  @moduledoc """
  A world map shape to paint on a `ExRatatui.Widgets.Canvas`.

  Plots Earth's continents inside the canvas' coordinate system. Pair
  with longitude/latitude bounds — `x_bounds: {-180.0, 180.0}` and
  `y_bounds: {-90.0, 90.0}` — to get a recognisable world view.

  ## Fields

    * `:resolution` - `:low` (~1000 points) or `:high` (~5000 points,
      best with the `:braille` marker); default `:low`
    * `:color` - `ExRatatui.Style.color()` for the map points (required)

  ## Examples

      iex> alias ExRatatui.Widgets.Canvas.Map
      iex> %Map{color: :green}
      %ExRatatui.Widgets.Canvas.Map{
        resolution: :low,
        color: :green
      }
  """

  @type resolution :: :low | :high

  @type t :: %__MODULE__{
          resolution: resolution(),
          color: ExRatatui.Style.color()
        }

  defstruct resolution: :low, color: nil
end
