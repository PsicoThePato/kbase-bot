defmodule KbaseBot.Tools.GrantScope do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Circles, Grants}

  @impl true
  def name, do: "grant_scope"

  @impl true
  def description do
    "Grant a contact (or 'anyone' for public, or circle:<name> for every current member of a circle) capabilities on a knowledge-base scope. Deny-by-default: nothing is shared until granted. medical/private and other flagged scopes can never be granted. Consider preview_grant first to see the blast radius."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{
          type: "string",
          description:
            "Contact principal id (sha256:...), 'anyone' for a public grant, or circle:<name> to grant to each current member"
        },
        scope: %{type: "string", description: "Scope label to grant, e.g. movies"},
        caps: %{
          type: "array",
          items: %{type: "string", enum: ["query", "read", "subscribe", "discuss"]},
          description: "Capabilities to grant (default: [\"query\"])"
        },
        depth: %{
          type: "integer",
          description:
            "Delegation depth (remaining hops the peer may re-delegate; default 0 = not delegable). Keep 0 unless you know why."
        },
        expires_in_days: %{
          type: "integer",
          description: "Optional expiry in days; omit for no expiry"
        }
      },
      required: ["principal_id", "scope"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      caps = input["caps"] || ["query"]
      depth = input["depth"] || 0

      caps_map = Map.new(caps, fn cap -> {cap, %{"depth" => depth}} end)

      caveats =
        case input["expires_in_days"] do
          days when is_integer(days) and days > 0 ->
            exp = DateTime.utc_now() |> DateTime.add(days * 86_400) |> DateTime.to_iso8601()
            %{"exp" => exp}

          _ ->
            %{}
        end

      principal = input["principal_id"]

      if Circles.ref?(principal) do
        grant_circle(Circles.ref_name(principal), input["scope"], caps, caps_map, caveats, depth)
      else
        case Grants.create(principal, input["scope"], caps_map, caveats) do
          {:ok, id} ->
            {:ok,
             "Grant #{id}: #{principal} may #{Enum.join(caps, "/")} " <>
               "on #{input["scope"]} (depth #{depth}#{expiry_note(caveats)})."}

          {:error, :no_identity} ->
            {:error, "no federation identity configured (FEDERATION_KEY_PATH)"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "could not create grant: #{inspect(reason)}"}
        end
      end
    end
  end

  # One ordinary signed grant per current member — the circle itself never
  # appears in a record, so the live grant table stays the only authority.
  defp grant_circle(name, scope, caps, caps_map, caveats, depth) do
    case Circles.members(name) do
      [] ->
        {:error, "circle #{name} is empty or unknown (see list_circles)"}

      members ->
        results = Enum.map(members, &{&1, Grants.create(&1, scope, caps_map, caveats)})

        granted = for {member, {:ok, id}} <- results, do: "#{id} → #{member}"
        failed = for {member, {:error, reason}} <- results, do: "#{member}: #{inspect(reason)}"

        summary =
          "Granted #{Enum.join(caps, "/")} on #{scope} (depth #{depth}#{expiry_note(caveats)}) " <>
            "to #{length(granted)}/#{length(members)} member(s) of #{name}:\n" <>
            Enum.join(granted, "\n")

        case failed do
          [] -> {:ok, summary}
          failures -> {:ok, summary <> "\nFailed:\n" <> Enum.join(failures, "\n")}
        end
    end
  end

  defp expiry_note(%{"exp" => exp}), do: ", expires #{exp}"
  defp expiry_note(_), do: ""
end
