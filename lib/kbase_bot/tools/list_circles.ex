defmodule KbaseBot.Tools.ListCircles do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Circles, Contacts}

  @impl true
  def name, do: "list_circles"

  @impl true
  def description, do: "List all circles and their members."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case Circles.list() do
        map when map_size(map) == 0 ->
          {:ok, "No circles. Create one with edit_circle."}

        circles ->
          lines =
            Enum.map_join(circles, "\n", fn {name, members} ->
              member_names = Enum.map_join(members, ", ", &display/1)
              "- #{name} (#{length(members)}): #{member_names}"
            end)

          {:ok, lines}
      end
    end
  end

  defp display(principal_id) do
    case Contacts.find(principal_id) do
      {:ok, %{display_name: name}} when is_binary(name) -> "#{name} (#{principal_id})"
      _ -> principal_id
    end
  end
end
