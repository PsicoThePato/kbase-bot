defmodule KbaseBot.Tools.GrantScope do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.Grants

  @impl true
  def name, do: "grant_scope"

  @impl true
  def description do
    "Grant a contact (or 'anyone' for public) capabilities on a knowledge-base scope. Deny-by-default: nothing is shared until granted. medical/private and other flagged scopes can never be granted."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{
          type: "string",
          description: "Contact principal id (sha256:...) or 'anyone' for a public grant"
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

      case Grants.create(input["principal_id"], input["scope"], caps_map, caveats) do
        {:ok, id} ->
          {:ok,
           "Grant #{id}: #{input["principal_id"]} may #{Enum.join(caps, "/")} " <>
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

  defp expiry_note(%{"exp" => exp}), do: ", expires #{exp}"
  defp expiry_note(_), do: ""
end
