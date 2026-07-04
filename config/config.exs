import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :ex_gram, token: {:system, "TELEGRAM_BOT_TOKEN"}

import_config "#{config_env()}.exs"
