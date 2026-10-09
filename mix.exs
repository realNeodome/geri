defmodule Geri.MixProject do
  use Mix.Project

  def project do
    [
      app: :geri,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      build_path: if(tui?(), do: "_build", else: "_build/headless"),
      escript: [main_module: Geri.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :iex]
    ]
  end

  defp tui?, do: System.get_env("GERI_TUI") != "false"

  defp deps do
    if tui?(), do: [{:ex_ratatui, "~> 0.14.0"}], else: []
  end
end
