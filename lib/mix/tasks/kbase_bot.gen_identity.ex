defmodule Mix.Tasks.KbaseBot.GenIdentity do
  @shortdoc "Generate the bot's Ed25519 federation identity"

  @moduledoc """
  Generates an Ed25519 keypair for federation and writes it (mode 0600) to
  the given path. Point FEDERATION_KEY_PATH at that file.

      mix kbase_bot.gen_identity priv/federation_identity.json
  """

  use Mix.Task

  @impl true
  def run([path]) do
    case KbaseBot.Identity.Keys.generate_to(path) do
      {:ok, principal_id} ->
        Mix.shell().info("Federation identity written to #{path}")
        Mix.shell().info("Principal id: #{principal_id}")
        Mix.shell().info("Set FEDERATION_KEY_PATH=#{path}")

      {:error, :already_exists} ->
        Mix.raise("#{path} already exists — refusing to overwrite an identity")

      {:error, reason} ->
        Mix.raise("Failed to generate identity: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix kbase_bot.gen_identity <path>")
end
