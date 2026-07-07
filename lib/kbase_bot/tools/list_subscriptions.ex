defmodule KbaseBot.Tools.ListSubscriptions do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "list_subscriptions"

  @impl true
  def description do
    "List federation subscriptions: 'out' = feeds we follow, 'in' = peers following our scopes."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case KbaseBot.Federation.Subscriptions.list() do
        [] ->
          {:ok, "No subscriptions."}

        subs ->
          lines =
            Enum.map(subs, fn s ->
              dir = if s.direction == "out", do: "we follow", else: "follows us:"
              topic = if s.topic && s.topic != s.scope, do: " → inbox/#{s.topic}/", else: ""
              "- [#{s.state}] #{dir} #{s.principal_id} · #{s.scope}#{topic}"
            end)

          {:ok, Enum.join(lines, "\n")}
      end
    end
  end
end
