import Config

config :logger, :default_handler,
  formatter:
    Logger.Formatter.new(
      format: "$time [$level] $message\n",
      metadata: []
    )
