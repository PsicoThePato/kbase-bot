import Config

# runtime.exs is skipped in test (no env vars required); provide the config
# that code under test reads, and don't boot the supervision tree.
config :kbase_bot,
  start_children?: false,
  model: "claude-sonnet-5"
