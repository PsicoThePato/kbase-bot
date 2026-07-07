defmodule KbaseBot.Tools.PublishItem do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "publish_item"

  @impl true
  def description do
    "Push a knowledge-base file to everyone subscribed to one of its scopes. Each recipient's live grant is re-verified, and the file's FULL scope set must be granted to them (intersection)."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        scope: %{type: "string", description: "The scope feed to publish on"},
        path: %{type: "string", description: "Relative KB path of the file to publish"}
      },
      required: ["scope", "path"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"scope" => scope, "path" => path}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      KbaseBot.Federation.Publisher.publish(scope, path)
    end
  end
end
