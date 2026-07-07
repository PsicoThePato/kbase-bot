defmodule KbaseBot.Tools.BindTopic do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "bind_topic"

  @impl true
  def description do
    "Bind one of your topics to a peer's scope label (owner-confirmed — outranks auto-proposed bindings). Queries and subscriptions by topic resolve through bindings."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        topic: %{type: "string", description: "Your topic label, e.g. health"},
        principal_id: %{type: "string", description: "The peer's principal id"},
        peer_scope: %{type: "string", description: "The peer's scope label, e.g. saude"}
      },
      required: ["topic", "principal_id", "peer_scope"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"topic" => topic, "principal_id" => peer, "peer_scope" => scope}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      KbaseBot.Federation.Bindings.upsert(topic, peer, scope, 100, true)
      {:ok, "Bound: your \"#{topic}\" ↔ #{peer}'s \"#{scope}\" (confirmed)."}
    end
  end
end
