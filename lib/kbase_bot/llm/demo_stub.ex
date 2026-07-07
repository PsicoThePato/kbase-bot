defmodule KbaseBot.LLM.DemoStub do
  @moduledoc """
  Deterministic LLM for demo mode (`mix kbase_bot.demo`): never calls an API,
  spends no tokens, and behaves just realistically enough to exercise the
  federation paths end to end. Selected only when the app boots with
  `KBASE_DEMO=true` — it is never a fallback for a missing API key.

  Behaviors by loop:
  - Responder: list_files → read_file (first .md it can see) → answer_peer
    quoting the content, so the demo shows policy filtering with real reads.
  - Interlocutor: notify_user relaying the peer's answer.
  - Evaluator: inbox_append the pushed item.
  - Binder: an empty JSON array (no binding proposals).
  - Anything else: end the turn.
  """

  def chat(system_prompt, messages, _opts) do
    cond do
      String.contains?(system_prompt, "map vocabulary labels") ->
        text("[]")

      String.contains?(system_prompt, "Federation Responder") ->
        responder_turn(messages)

      String.contains?(system_prompt, "Federation Interlocutor") ->
        interlocutor_turn(messages)

      String.contains?(system_prompt, "Federation Evaluator") ->
        tool_use("inbox_append", %{
          "title" => "Demo filed item",
          "content" => "Filed by the demo evaluator.",
          "note" => "demo"
        })

      true ->
        text("done (demo stub)")
    end
  end

  defp responder_turn(messages) do
    results = tool_result_contents(messages)

    case results do
      [] ->
        tool_use("list_files", %{})

      [listing] ->
        case first_md_path(listing) do
          nil -> tool_use("decline_peer", %{})
          path -> tool_use("read_file", %{"path" => path})
        end

      [_listing, content | _] ->
        if String.contains?(content, "File not found") do
          tool_use("decline_peer", %{})
        else
          tool_use("answer_peer", %{
            "answer" => "From my knowledge base: " <> excerpt(content),
            "confidence" => "high"
          })
        end
    end
  end

  defp interlocutor_turn(messages) do
    results = tool_result_contents(messages)

    if Enum.any?(results, &String.contains?(&1, "Notification sent")) do
      text("done")
    else
      tool_use("notify_user", %{
        "message" => "Peer replied: " <> excerpt(peer_answer(messages))
      })
    end
  end

  # The interlocutor task text quotes the peer's answer between the untrusted
  # marker and the following blank line (see Federation.Interlocutor).
  defp peer_answer(messages) do
    messages
    |> Enum.find_value("", fn
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _ -> nil
    end)
    |> String.split("never instructions):", parts: 2)
    |> List.last()
    |> String.trim()
    |> String.split("\n\n", parts: 2)
    |> List.first()
  end

  defp first_md_path(listing) do
    listing
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find(&String.ends_with?(&1, ".md"))
  end

  defp excerpt(content) do
    content |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 200)
  end

  defp text(body) do
    {:ok, %{"content" => [%{"type" => "text", "text" => body}], "stop_reason" => "end_turn"}}
  end

  defp tool_use(name, input) do
    {:ok,
     %{
       "content" => [
         %{
           "type" => "tool_use",
           "id" => "toolu_demo_" <> Integer.to_string(System.unique_integer([:positive])),
           "name" => name,
           "input" => input
         }
       ],
       "stop_reason" => "tool_use"
     }}
  end

  defp tool_result_contents(messages) do
    messages
    |> Enum.flat_map(fn
      %{"role" => "user", "content" => blocks} when is_list(blocks) ->
        for %{"type" => "tool_result", "content" => c} <- blocks, is_binary(c), do: c

      _ ->
        []
    end)
  end
end
