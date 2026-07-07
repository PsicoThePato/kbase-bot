defmodule KbaseBot.Tools.ShowFederationCard do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Card, Grants, Verifier}

  @impl true
  def name, do: "show_federation_card"

  @impl true
  def description do
    "Produce this bot's signed federation contact card (JSON) for the owner to share with a friend. The friend pastes it into their own bot with add_contact."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      endpoints =
        case Application.get_env(:kbase_bot, :federation_public_url) do
          nil ->
            []

          url ->
            [
              %{
                "transport" => "https",
                "address" => String.trim_trailing(url, "/") <> "/federation/inbox",
                "priority" => 1
              }
            ]
        end

      public_scopes = Grants.granted_scopes(Verifier.anyone())
      display_name = Application.get_env(:kbase_bot, :federation_display_name, "KbaseBot")
      seq = System.os_time(:second)

      # After a key rotation the proof rides on every card, so even a
      # manually re-shared card migrates peers still on the old identity.
      rotation = KbaseBot.Federation.Rotation.proof()

      case Card.build(display_name, seq, endpoints, public_scopes, rotation) do
        {:ok, card} ->
          {:ok, "Our federation card (share this JSON):\n" <> Jason.encode!(card)}

        {:error, :no_identity} ->
          {:error,
           "no federation identity — run mix kbase_bot.gen_identity and set FEDERATION_KEY_PATH"}

        {:error, reason} ->
          {:error, "could not build card: #{inspect(reason)}"}
      end
    end
  end
end
