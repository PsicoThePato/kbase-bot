defmodule KbaseBot.Memory.VoyageClient do
  @moduledoc """
  Calls the Voyage AI embeddings API to generate vector embeddings.
  """

  require Logger

  @url "https://api.voyageai.com/v1/embeddings"
  @model "voyage-3-lite"

  def embed(texts) when is_list(texts) and texts != [] do
    api_key = Application.fetch_env!(:kbase_bot, :voyage_api_key)

    case Req.post(@url,
           json: %{input: texts, model: @model},
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        embeddings =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Voyage API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Voyage API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def embed([]), do: {:ok, []}
end
