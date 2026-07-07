defmodule KbaseBot.Tools.DiscussPeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Bindings, Discussion}

  @impl true
  def name, do: "discuss_peer"

  @impl true
  def description do
    "Open a multi-turn discussion with a peer's agent in one of THEIR scopes. Your opening message is the ONLY owner-voice disclosure — replies are handled by a subagent that can read only what THAT PEER is granted (clearance rule), so put everything the discussion needs into the opening."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string", description: "The contact's principal id"},
        scope: %{type: "string", description: "THEIR scope label (or pass topic)"},
        topic: %{type: "string", description: "YOUR topic — resolved via bindings"},
        opening: %{
          type: "string",
          description:
            "The opening message + implicit brief, composed for external ears. Sent verbatim."
        }
      },
      required: ["principal_id", "opening"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => peer, "opening" => opening} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, scope} <- resolve_scope(input, peer),
         {:ok, thread_id} <- Discussion.open_from_owner(peer, scope, opening) do
      {:ok,
       "Discussion #{thread_id} opened with #{peer} on their scope #{scope}. " <>
         "Replies are handled at that peer's clearance; outcomes surface as [Federation] messages."}
    else
      {:error, :no_identity} -> {:error, "no federation identity configured"}
      {:error, :unknown_contact} -> {:error, "unknown contact #{peer}"}
      err -> err
    end
  end

  defp resolve_scope(%{"scope" => scope}, _peer) when is_binary(scope) and scope != "" do
    {:ok, scope}
  end

  defp resolve_scope(%{"topic" => topic}, peer) when is_binary(topic) and topic != "" do
    case Bindings.resolve(topic, peer) do
      [best | _] -> {:ok, best}
      [] -> {:error, "no binding for topic \"#{topic}\" at this peer — pass scope explicitly"}
    end
  end

  defp resolve_scope(_, _), do: {:error, "pass either scope or topic"}
end
