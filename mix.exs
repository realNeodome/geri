Code.require_file("build_support/version.exs", __DIR__)

defmodule Geri.MixProject do
  use Mix.Project
  @external_resource "build_support/version.exs"

  def project do
    [
      app: :geri,
      version: Geri.BuildVersion.version(__DIR__, "0.1.0"),
      # Git tags/commits can change without changing a source file's mtime.
      aliases: ["compile.app": "compile.app --force"],
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
    if tui?(),
      do: [{:ex_ratatui, path: "vendor/ex_ratatui"}, {:rustler, "~> 0.38.0", runtime: false}],
      else: []
  end
end
