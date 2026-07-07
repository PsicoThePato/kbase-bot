defmodule KbaseBot.Tools.ListContacts do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.Contacts

  @impl true
  def name, do: "list_contacts"

  @impl true
  def description, do: "List the federation address book (peers and their contact cards)."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case Contacts.list() do
        [] ->
          {:ok, "No contacts yet."}

        contacts ->
          lines =
            Enum.map(contacts, fn c ->
              endpoints =
                (c.card["endpoints"] || [])
                |> Enum.map_join(", ", & &1["transport"])

              "- #{c.display_name || "?"} (#{c.principal_id}) — card seq #{c.card_seq}, transports: #{endpoints}"
            end)

          {:ok, Enum.join(lines, "\n")}
      end
    end
  end
end
