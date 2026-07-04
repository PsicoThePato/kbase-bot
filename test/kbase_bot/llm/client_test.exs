defmodule KbaseBot.LLM.ClientTest do
  use ExUnit.Case, async: true

  alias KbaseBot.LLM.Client

  describe "to_message_param/1" do
    test "converts top-level string keys to the atoms Anthropix expects" do
      assert Client.to_message_param(%{"role" => "user", "content" => "hi"}) ==
               %{role: "user", content: "hi"}
    end

    test "leaves model-controlled content block keys as strings" do
      blocks = [
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "search_knowledge",
          "input" => %{"query" => "training", "arbitrary_model_key" => 1}
        }
      ]

      assert Client.to_message_param(%{"role" => "assistant", "content" => blocks}) ==
               %{role: "assistant", content: blocks}
    end

    test "passes through already atom-keyed messages" do
      message = %{role: "user", content: "hi"}
      assert Client.to_message_param(message) == message
    end
  end
end
