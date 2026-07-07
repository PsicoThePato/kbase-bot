defmodule KbaseBot.Tools.ListPendingDeliveries do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Contacts, OutboundQueue}

  @impl true
  def name, do: "list_pending_deliveries"

  @impl true
  def description do
    "Show the store-and-forward delivery queue: envelopes waiting for unreachable peers (retried with backoff for up to 7 days) and dead-lettered ones that never got through."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case OutboundQueue.status() do
        [] ->
          {:ok, "Delivery queue is empty — everything got through."}

        rows ->
          lines =
            Enum.map_join(rows, "\n", fn row ->
              oldest = row.oldest && String.slice(row.oldest, 0, 16)

              "- #{display(row.peer)}: #{row.count} #{row.state} (oldest #{oldest}" <>
                if(row.last_error, do: ", last error #{row.last_error})", else: ")")
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
