defmodule KbaseBot.Tools.RevokeGrant do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "revoke_grant"

  @impl true
  def description do
    "Revoke a grant by id (see list_grants). Takes effect immediately — the live grant graph is the source of truth."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{grant_id: %{type: "string", description: "The grant id to revoke"}},
      required: ["grant_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"grant_id" => id}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case KbaseBot.Federation.Grants.revoke(id) do
        :ok -> {:ok, "Grant #{id} revoked."}
        {:error, :not_found} -> {:error, "no live grant with id #{id}"}
      end
    end
  end
end
