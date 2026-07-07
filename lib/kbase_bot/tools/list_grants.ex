defmodule KbaseBot.Tools.ListGrants do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "list_grants"

  @impl true
  def description, do: "List all grants (live and revoked) with their ids, audiences and scopes."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case KbaseBot.Federation.Grants.list() do
        [] ->
          {:ok, "No grants."}

        grants ->
          lines =
            Enum.map(grants, fn g ->
              caps =
                Enum.map_join(g.caps, ", ", fn {cap, %{"depth" => d}} -> "#{cap}(depth #{d})" end)

              status = if g.revoked_at, do: " [REVOKED #{g.revoked_at}]", else: ""
              "- #{g.id}: #{g.aud} → #{g.scope}: #{caps}#{status}"
            end)

          {:ok, Enum.join(lines, "\n")}
      end
    end
  end
end
