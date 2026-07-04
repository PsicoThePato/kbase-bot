defmodule KbaseBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :kbase_bot,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        kbase_bot: [
          include_erts: true,
          strip_beams: true
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {KbaseBot.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_gram, "~> 0.53"},
      {:tesla, "~> 1.9"},
      {:hackney, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:anthropix, "~> 0.6"},
      {:exqlite, "~> 0.23"},
      {:tzdata, "~> 1.1"},
      {:crontab, "~> 1.1"},
      {:nx, "~> 0.7"},
      {:req, "~> 0.5"}
    ]
  end
end
