defmodule KbaseBot.Test.FakeLLM do
  @moduledoc """
  Deterministic LLM stub for federation integration tests. First call in a
  session returns an `answer_peer` tool_use built from the latest user
  message; after a tool_result appears it returns plain text (loop ends).
  """

  def chat(system_prompt, messages, _opts) do
    cond do
      # Discussant: probe clearance by reading a private file, then say what
      # happened. Turn 1: read_file secret.md; turn 2: say READ-DENIED/READ-OK.
      String.contains?(system_prompt, "Federation Discussant") ->
        discussant_turn(messages)

      # Interlocutor (outbound answer handler): probe clearance, then report
      # to the owner via notify_user. Turn 1: read secret.md; turn 2:
      # notify_user with the clearance outcome; then stop.
      String.contains?(system_prompt, "Federation Interlocutor") ->
        interlocutor_turn(messages)

      has_tool_result?(messages) ->
        {:ok,
         %{"content" => [%{"type" => "text", "text" => "done"}], "stop_reason" => "end_turn"}}

      String.contains?(system_prompt, "Federation Evaluator") ->
        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "toolu_fake_2",
               "name" => "inbox_append",
               "input" => %{
                 "title" => "Fake filed item",
                 "content" => "FAKE-FILED: pushed content",
                 "note" => "stub says interesting"
               }
             }
           ],
           "stop_reason" => "tool_use"
         }}

      true ->
        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "toolu_fake_1",
               "name" => "answer_peer",
               "input" => %{"answer" => "FAKE-ANSWER: movies content", "confidence" => "high"}
             }
           ],
           "stop_reason" => "tool_use"
         }}
    end
  end

  defp discussant_turn(messages) do
    results = tool_result_contents(messages)

    cond do
      # Already said something this session — stop.
      Enum.any?(results, &String.contains?(&1, "Sent.")) ->
        {:ok,
         %{"content" => [%{"type" => "text", "text" => "waiting"}], "stop_reason" => "end_turn"}}

      # Second turn: report the read outcome via say.
      results != [] ->
        outcome =
          if Enum.any?(results, &String.contains?(&1, "File not found")),
            do: "READ-DENIED",
            else: "READ-OK"

        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "toolu_fake_say",
               "name" => "say",
               "input" => %{"message" => outcome}
             }
           ],
           "stop_reason" => "tool_use"
         }}

      # First turn: probe the clearance boundary.
      true ->
        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "toolu_fake_read",
               "name" => "read_file",
               "input" => %{"path" => "secret.md"}
             }
           ],
           "stop_reason" => "tool_use"
         }}
    end
  end

  defp interlocutor_turn(messages) do
    results = tool_result_contents(messages)

    cond do
      # Already notified the owner — stop.
      Enum.any?(results, &String.contains?(&1, "Notification sent.")) ->
        {:ok,
         %{"content" => [%{"type" => "text", "text" => "done"}], "stop_reason" => "end_turn"}}

      # Second turn: report the clearance outcome to the owner.
      results != [] ->
        outcome =
          if Enum.any?(results, &String.contains?(&1, "File not found")),
            do: "READ-DENIED",
            else: "READ-OK"

        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "toolu_fake_notify",
               "name" => "notify_user",
               "input" => %{"message" => "REPORT: peer replied; private read = #{outcome}"}
             }
           ],
           "stop_reason" => "tool_use"
         }}

      # First turn: probe the clearance boundary.
      true ->
        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "toolu_fake_iread",
               "name" => "read_file",
               "input" => %{"path" => "secret.md"}
             }
           ],
           "stop_reason" => "tool_use"
         }}
    end
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

  defp has_tool_result?(messages) do
    Enum.any?(messages, fn
      %{"role" => "user", "content" => blocks} when is_list(blocks) ->
        Enum.any?(blocks, &(is_map(&1) and &1["type"] == "tool_result"))

      _ ->
        false
    end)
  end
end
