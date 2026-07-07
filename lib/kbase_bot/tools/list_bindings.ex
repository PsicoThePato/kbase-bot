defmodule KbaseBot.Tools.ListBindings do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "list_bindings"

  @impl true
  def description, do: "List topic↔peer-scope bindings (the federation translation layer)."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case KbaseBot.Federation.Bindings.list() do
        [] ->
          {:ok, "No bindings yet. They appear after list_peer_scopes (auto) or bind_topic."}

        bindings ->
          lines =
            Enum.map(bindings, fn b ->
              status = if b.confirmed, do: "confirmed", else: "auto #{b.confidence}%"
              "- #{b.topic} ↔ #{b.principal_id}:#{b.peer_scope} (#{status})"
            end)

          {:ok, Enum.join(lines, "\n")}
      end
    end
  end
end
