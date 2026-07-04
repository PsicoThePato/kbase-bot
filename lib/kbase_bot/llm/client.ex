defmodule KbaseBot.LLM.Client do
  @moduledoc """
  Wraps Anthropix with retry logic and ephemeral cache control.
  Adapted from aifred-web's anthropic.rs retry pattern.
  """

  require Logger

  @max_retries 3
  @retry_base_ms 1_000
  # claude-sonnet-5 runs adaptive thinking by default, and thinking tokens
  # share this budget with the visible reply — leave headroom.
  @default_max_tokens 8192
  @rate_limit_wait_ms 60_000

  @doc """
  Send a chat request to Claude with tool definitions.

  Options:
    - :model - model ID (default: the :model application env / MODEL env var)
    - :max_tokens - max response tokens (default: 8192)
    - :tools - list of tool schemas (Anthropic format, atom keys at the top level)
  """
  def chat(system, messages, opts \\ []) do
    model = Keyword.get(opts, :model) || default_model()
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    tools = Keyword.get(opts, :tools, [])

    converted_messages = Enum.map(messages, &to_message_param/1)

    # Use content block format for system prompt to enable caching
    system_blocks = [
      %{type: "text", text: system, cache_control: %{type: "ephemeral"}}
    ]

    anthropix_opts = [
      model: model,
      max_tokens: max_tokens,
      system: system_blocks,
      messages: converted_messages
    ]

    anthropix_opts =
      if tools != [] do
        # Add cache_control to the last tool to cache the entire tool block
        cached_tools = cache_last_tool(tools)
        Keyword.put(anthropix_opts, :tools, cached_tools)
      else
        anthropix_opts
      end

    do_request(anthropix_opts, 0)
  end

  defp cache_last_tool([]), do: []

  defp cache_last_tool(tools) do
    {last, rest} = List.pop_at(tools, -1)
    rest ++ [Map.put(last, :cache_control, %{type: "ephemeral"})]
  end

  defp do_request(opts, attempt) when attempt < @max_retries do
    client = Anthropix.init(api_key())

    case Anthropix.chat(client, opts) do
      {:ok, %{"type" => "error", "error" => %{"type" => error_type}} = error} ->
        if retryable_error?(error_type) do
          retry(opts, attempt, "API error: #{error_type}")
        else
          Logger.error("Non-retryable API error: #{inspect(error)}")
          {:error, {:api_error, error_type, error}}
        end

      {:ok, %{"content" => _content} = response} ->
        {:ok, response}

      {:error, %Anthropix.APIError{status: 429}} ->
        retry(opts, attempt, "Rate limited", @rate_limit_wait_ms)

      {:error, reason} ->
        retry(opts, attempt, "HTTP error: #{inspect(reason)}")
    end
  end

  defp do_request(_opts, _attempt) do
    Logger.error("LLM client: max retries exceeded")
    {:error, :max_retries_exceeded}
  end

  defp retry(opts, attempt, reason, delay \\ nil) do
    delay = delay || @retry_base_ms * Integer.pow(2, attempt)

    Logger.warning(
      "LLM retry attempt #{attempt + 1}/#{@max_retries}: #{reason}, waiting #{delay}ms"
    )

    Process.sleep(delay)
    do_request(opts, attempt + 1)
  end

  defp retryable_error?(error_type) do
    error_type in ["overloaded_error", "api_error", "rate_limit_error"]
  end

  defp api_key do
    Application.fetch_env!(:kbase_bot, :anthropic_api_key)
  end

  defp default_model do
    Application.fetch_env!(:kbase_bot, :model)
  end

  @doc """
  Extract text content from an Anthropic API response.
  """
  def extract_text(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.join("")
  end

  def extract_text(_), do: ""

  @doc """
  Extract tool use blocks from an Anthropic API response.
  """
  def extract_tool_calls(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(fn block ->
      %{
        id: block["id"],
        name: block["name"],
        input: block["input"]
      }
    end)
  end

  def extract_tool_calls(_), do: []

  @doc """
  Check if the response's stop_reason indicates tool use.
  """
  def needs_tool_response?(%{"stop_reason" => "tool_use"}), do: true
  def needs_tool_response?(_), do: false

  # --- Key conversion ---

  # Anthropix only requires the top-level :role/:content keys to be atoms;
  # content blocks accept string keys. Leave them untouched so keys chosen by
  # the model (tool-input JSON, etc.) never become atoms — atoms are not
  # garbage-collected, so converting model output would leak the atom table.
  @doc false
  def to_message_param(%{"role" => role, "content" => content}) do
    %{role: role, content: content}
  end

  def to_message_param(%{role: _, content: _} = message), do: message
end
