defmodule KbaseBot.Test.FakeLLM do
  @moduledoc """
  Deterministic LLM stub for federation integration tests. First call in a
  session returns an `answer_peer` tool_use built from the latest user
  message; after a tool_result appears it returns plain text (loop ends).
  """

  def chat(_system_prompt, messages, _opts) do
    if has_tool_result?(messages) do
      {:ok, %{"content" => [%{"type" => "text", "text" => "done"}], "stop_reason" => "end_turn"}}
    else
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

  defp has_tool_result?(messages) do
    Enum.any?(messages, fn
      %{"role" => "user", "content" => blocks} when is_list(blocks) ->
        Enum.any?(blocks, &(is_map(&1) and &1["type"] == "tool_result"))

      _ ->
        false
    end)
  end
end
