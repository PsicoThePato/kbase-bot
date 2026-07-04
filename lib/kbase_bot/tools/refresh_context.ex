defmodule KbaseBot.Tools.RefreshContext do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "refresh_context"

  @impl true
  def description,
    do:
      "Reload the knowledge base context from disk. Use after files have been modified externally."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    KbaseBot.Context.Server.refresh()
    {:ok, "Context refreshed."}
  end
end
