defmodule ExRatatui.Widgets.SlashCommands.Command do
  @moduledoc """
  A slash command definition with name, description, and optional aliases.

  ## Examples

      iex> %ExRatatui.Widgets.SlashCommands.Command{name: "help", description: "Show help"}
      %ExRatatui.Widgets.SlashCommands.Command{name: "help", description: "Show help", aliases: []}

      iex> %ExRatatui.Widgets.SlashCommands.Command{name: "quit", aliases: ["exit", "q"]}
      %ExRatatui.Widgets.SlashCommands.Command{name: "quit", description: "", aliases: ["exit", "q"]}
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          aliases: [String.t()]
        }

  defstruct name: "", description: "", aliases: []
end
