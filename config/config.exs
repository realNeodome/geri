import Config

config :logger, :default_handler,
  formatter:
    Logger.Formatter.new(
      format: "$time [$level] $message\n",
      metadata: []
    )

# The bundled ExRatatui adds text_widths/1, absent from upstream binaries.
if System.get_env("GERI_TUI") != "false" do
  config :rustler_precompiled, :force_build, ex_ratatui: true
end
