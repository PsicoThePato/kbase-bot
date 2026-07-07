defmodule KbaseBot.Tools.AddContact do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.Contacts

  @impl true
  def name, do: "add_contact"

  @impl true
  def description do
    "Add a peer to the federation address book from their signed contact card (JSON pasted by the owner). Adding a contact grants NOTHING — use grant_scope for that."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        card_json: %{type: "string", description: "The peer's contact card JSON, verbatim"},
        notes: %{type: "string", description: "Optional owner notes about this contact"}
      },
      required: ["card_json"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"card_json" => card_json} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, card} <- Jason.decode(card_json),
         {:ok, principal_id} <- Contacts.add_card(card, input["notes"]) do
      {:ok, "Contact #{card["display_name"]} added (#{principal_id}). No grants yet."}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "card is not valid JSON"}
      {:error, :invalid_card} -> {:error, "card failed verification (signature/fingerprint)"}
      {:error, :stale_card} -> {:error, "we already hold a newer card for this principal"}
      err -> err
    end
  end
end
