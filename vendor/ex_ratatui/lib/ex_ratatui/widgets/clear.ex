defmodule ExRatatui.Widgets.Clear do
  @moduledoc """
  A widget that resets all cells in its area to empty (space) characters.

  Useful for rendering overlays on top of existing content — render a `Clear`
  over the area first, then render the overlay widget on top.

  ## Examples

      iex> %ExRatatui.Widgets.Clear{}
      %ExRatatui.Widgets.Clear{}
  """

  @type t :: %__MODULE__{}

  defstruct []
end
