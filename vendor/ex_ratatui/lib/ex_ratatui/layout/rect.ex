defmodule ExRatatui.Layout.Rect do
  @moduledoc """
  A rectangular area on the terminal screen.

  ## Fields

    * `:x` - left column (0-based)
    * `:y` - top row (0-based)
    * `:width` - width in cells
    * `:height` - height in cells

  ## Examples

      iex> %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 24}
      %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 24}

      iex> %ExRatatui.Layout.Rect{}
      %ExRatatui.Layout.Rect{x: 0, y: 0, width: 0, height: 0}
  """

  @type t :: %__MODULE__{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  defstruct x: 0, y: 0, width: 0, height: 0
end
