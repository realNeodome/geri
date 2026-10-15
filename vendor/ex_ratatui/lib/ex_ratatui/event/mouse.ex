defmodule ExRatatui.Event.Mouse do
  @moduledoc """
  A mouse event.

  ## Fields

    * `:kind` - the type of mouse event: `"down"`, `"up"`, `"drag"`, `"moved"`,
      `"scroll_up"`, `"scroll_down"`, `"scroll_left"`, `"scroll_right"`
    * `:button` - the mouse button: `"left"`, `"right"`, `"middle"`, or `""`
      (empty for scroll and move events)
    * `:x` - column position (0-based)
    * `:y` - row position (0-based)
    * `:modifiers` - list of active modifiers: `"shift"`, `"ctrl"`, `"alt"`,
      `"super"`, `"hyper"`, `"meta"`

  ## Examples

      iex> %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 5, y: 10}
      %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 5, y: 10, modifiers: []}

  Pattern matching on events:

      # Match a left click
      %Event.Mouse{kind: "down", button: "left", x: x, y: y}

      # Match scroll up
      %Event.Mouse{kind: "scroll_up"}
  """

  @type t :: %__MODULE__{
          kind: String.t(),
          button: String.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          modifiers: [String.t()]
        }

  defstruct [:kind, :button, :x, :y, modifiers: []]
end
