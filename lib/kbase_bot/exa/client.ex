defmodule KbaseBot.Exa.Client do
  @base_url "https://api.exa.ai"

  def search(query, opts \\ %{}) do
    body =
      %{
        "query" => query,
        "numResults" => Map.get(opts, "num_results", 5),
        "contents" => %{
          "highlights" => %{"maxCharacters" => 2000},
          "summary" => true
        }
      }
      |> maybe_put("category", opts["category"])

    case req(:post, "/search", json: body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "Exa API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Exa request failed: #{inspect(reason)}"}
    end
  end

  defp req(method, path, opts) do
    api_key = Application.fetch_env!(:kbase_bot, :exa_api_key)

    Req.request(
      [
        {:method, method},
        {:url, @base_url <> path},
        {:headers, [{"x-api-key", api_key}]},
        {:receive_timeout, 30_000}
      ] ++ opts
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
