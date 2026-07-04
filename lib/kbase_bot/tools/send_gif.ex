defmodule KbaseBot.Tools.SendGif do
  @behaviour KbaseBot.Tool

  require Logger

  @giphy_url "https://api.giphy.com/v1/gifs/search"

  @impl true
  def name, do: "send_gif"

  @impl true
  def description do
    "Search for a GIF and send it to the user via Telegram. Great for adding personality to messages like daily briefings, celebrations, or motivation."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description:
            "Search query for the GIF (e.g. 'workout motivation', 'good morning', 'lets go')"
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def layer, do: :both

  @impl true
  def execute(%{"query" => query}, context) do
    api_key = Application.get_env(:kbase_bot, :giphy_api_key)

    if is_nil(api_key) or api_key == "" do
      {:ok, "GIF feature not configured (no GIPHY API key)."}
    else
      chat_id =
        Map.get(context, :chat_id) || Application.fetch_env!(:kbase_bot, :telegram_chat_id)

      case search_giphy(query, api_key) do
        {:ok, gif_url} ->
          send_animation(chat_id, gif_url)
          {:ok, "GIF sent."}

        {:error, reason} ->
          Logger.warning("GIF search failed: #{reason}")
          {:ok, "Couldn't find a GIF, but that's fine."}
      end
    end
  end

  defp search_giphy(query, api_key) do
    url = "#{@giphy_url}?api_key=#{api_key}&q=#{URI.encode(query)}&limit=5&rating=pg-13"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"data" => [first | _]}}} ->
        gif_url = get_in(first, ["images", "original", "url"])
        {:ok, gif_url}

      {:ok, %{status: 200, body: %{"data" => []}}} ->
        {:error, "no results"}

      {:ok, %{status: status}} ->
        {:error, "GIPHY returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp send_animation(chat_id, gif_url) do
    token = Application.fetch_env!(:kbase_bot, :telegram_bot_token)

    Req.post("https://api.telegram.org/bot#{token}/sendAnimation",
      json: %{chat_id: chat_id, animation: gif_url}
    )
  end
end
