defmodule KbaseBot.Tools.UnbindTopic do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "unbind_topic"

  @impl true
  def description do
    "Remove a topic↔peer-scope binding (or all bindings of a topic at that peer when peer_scope is omitted)."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        topic: %{type: "string"},
        principal_id: %{type: "string"},
        peer_scope: %{type: "string", description: "Omit to remove all for this topic+peer"}
      },
      required: ["topic", "principal_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"topic" => topic, "principal_id" => peer} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      KbaseBot.Federation.Bindings.delete(topic, peer, input["peer_scope"])
      {:ok, "Unbound #{topic} at #{peer}."}
    end
  end
end
