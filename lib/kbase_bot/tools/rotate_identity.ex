defmodule KbaseBot.Tools.RotateIdentity do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.Rotation

  @impl true
  def name, do: "rotate_identity"

  @impl true
  def description do
    "Rotate this bot's federation keypair: generates a new Ed25519 identity, signs a rotation proof with the current key, re-signs live grants, and broadcasts the new card to every contact (queued for offline peers). Use when the key may be compromised or as periodic hygiene. Requires confirm=true — the owner must have explicitly asked for a rotation in this conversation."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        confirm: %{
          type: "boolean",
          description: "Must be true; set it only on the owner's explicit instruction"
        }
      },
      required: ["confirm"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"confirm" => true}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case Rotation.rotate_own() do
        {:ok, %{old_id: old_id, new_id: new_id, notified: notified}} ->
          {:ok,
           "Identity rotated: #{old_id} → #{new_id}. Rotation card sent to " <>
             "#{notified} contact(s) (queued for any that are offline). The old key " <>
             "file was kept as a .pre-rotation backup. Peers on the old id migrate " <>
             "automatically when they see the new card."}

        {:error, :no_identity} ->
          {:error, "no federation identity configured (FEDERATION_KEY_PATH)"}

        {:error, reason} ->
          {:error, "rotation failed: #{inspect(reason)}"}
      end
    end
  end

  def execute(_input, _context) do
    {:error, "rotation not confirmed — pass confirm=true only on explicit owner instruction"}
  end
end
