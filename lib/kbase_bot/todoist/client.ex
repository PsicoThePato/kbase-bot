defmodule KbaseBot.Todoist.Client do
  @moduledoc """
  Todoist REST API v1 client.
  """

  require Logger

  @base_url "https://api.todoist.com/api/v1"

  def list_tasks do
    case req(:get, "/tasks") do
      {:ok, %{status: 200, body: %{"results" => tasks}}} ->
        {:ok, tasks}

      {:ok, %{status: status, body: body}} ->
        {:error, "Todoist API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Todoist request failed: #{inspect(reason)}"}
    end
  end

  def create_task(content, opts \\ %{}) do
    body =
      %{"content" => content}
      |> maybe_put("due_string", opts["due_string"])
      |> maybe_put("priority", opts["priority"])
      |> maybe_put("description", opts["description"])

    case req(:post, "/tasks", json: body) do
      {:ok, %{status: 200, body: task}} ->
        {:ok, task}

      {:ok, %{status: status, body: body}} ->
        {:error, "Todoist API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Todoist request failed: #{inspect(reason)}"}
    end
  end

  def close_task(id) do
    case req(:post, "/tasks/#{id}/close") do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "Todoist API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Todoist request failed: #{inspect(reason)}"}
    end
  end

  def delete_task(id) do
    case req(:delete, "/tasks/#{id}") do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "Todoist API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Todoist request failed: #{inspect(reason)}"}
    end
  end

  defp req(method, path, opts \\ []) do
    api_key = Application.fetch_env!(:kbase_bot, :todoist_api_key)

    Req.request(
      [
        {:method, method},
        {:url, @base_url <> path},
        {:headers, [{"authorization", "Bearer #{api_key}"}]},
        {:receive_timeout, 15_000}
      ] ++ opts
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
