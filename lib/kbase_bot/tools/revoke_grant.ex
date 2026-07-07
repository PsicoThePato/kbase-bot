defmodule KbaseBot.Tools.RevokeGrant do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Circles, Grants}

  @impl true
  def name, do: "revoke_grant"

  @impl true
  def description do
    "Revoke grants — by grant id (see list_grants), or in bulk by principal_id + scope (every live grant that pair holds), or by circle:<name> + scope (each member). Takes effect immediately — the live grant graph is the source of truth."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        grant_id: %{type: "string", description: "A single grant id to revoke"},
        principal_id: %{
          type: "string",
          description:
            "With scope: revoke all live grants for this principal (or circle:<name>) on that scope"
        },
        scope: %{type: "string", description: "Scope for principal_id/circle bulk revocation"}
      }
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case input do
        %{"grant_id" => id} when is_binary(id) and id != "" ->
          case Grants.revoke(id) do
            :ok -> {:ok, "Grant #{id} revoked."}
            {:error, :not_found} -> {:error, "no live grant with id #{id}"}
          end

        %{"principal_id" => principal, "scope" => scope}
        when is_binary(principal) and is_binary(scope) ->
          principals =
            if Circles.ref?(principal),
              do: Circles.members(Circles.ref_name(principal)),
              else: [principal]

          case principals do
            [] ->
              {:error, "circle is empty or unknown (see list_circles)"}

            principals ->
              revoked = Enum.map(principals, &revoke_pair(&1, scope))
              total = Enum.sum(revoked)

              {:ok,
               "Revoked #{total} grant(s) on #{scope} across " <>
                 "#{length(principals)} principal(s)."}
          end

        _ ->
          {:error, "pass grant_id, or principal_id (or circle:<name>) together with scope"}
      end
    end
  end

  defp revoke_pair(principal, scope) do
    Grants.list()
    |> Enum.filter(fn g -> g.aud == principal and g.scope == scope and g.revoked_at == nil end)
    |> Enum.count(fn g -> Grants.revoke(g.id) == :ok end)
  end
end
