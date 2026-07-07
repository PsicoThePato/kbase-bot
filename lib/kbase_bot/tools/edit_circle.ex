defmodule KbaseBot.Tools.EditCircle do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.Circles

  @impl true
  def name, do: "edit_circle"

  @impl true
  def description do
    "Add/remove contacts in a named circle (owner-local peer group). Circles are pure address-book convenience: grant_scope to circle:<name> expands to one grant per CURRENT member — joining later grants nothing retroactively."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "Circle name (lowercase slug, e.g. friends)"},
        add: %{
          type: "array",
          items: %{type: "string"},
          description: "Contact principal ids to add"
        },
        remove: %{
          type: "array",
          items: %{type: "string"},
          description: "Contact principal ids to remove"
        }
      },
      required: ["name"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"name" => name} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      added =
        (input["add"] || [])
        |> Enum.map(fn id ->
          case Circles.add(name, id) do
            :ok -> {:ok, id}
            {:error, :unknown_contact} -> {:skip, "#{id} (not a known contact)"}
            {:error, reason} -> {:halt, to_string(reason)}
          end
        end)

      case Enum.find(added, &match?({:halt, _}, &1)) do
        {:halt, reason} ->
          {:error, reason}

        nil ->
          Enum.each(input["remove"] || [], &Circles.remove(name, &1))

          skipped = for {:skip, note} <- added, do: note
          members = Circles.members(name)

          {:ok,
           "Circle #{name}: #{length(members)} member(s)." <>
             if(skipped != [], do: " Skipped: #{Enum.join(skipped, ", ")}.", else: "")}
      end
    end
  end
end
