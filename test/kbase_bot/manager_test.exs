defmodule KbaseBot.ManagerTest do
  use ExUnit.Case, async: true

  import KbaseBot.Manager, only: [trim_orphan_tool_use: 1]

  defp user(text), do: %{"role" => "user", "content" => text}

  defp assistant_text(text),
    do: %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}

  defp assistant_tool_use(id) do
    %{
      "role" => "assistant",
      "content" => [%{"type" => "tool_use", "id" => id, "name" => "x", "input" => %{}}]
    }
  end

  defp tool_result(id) do
    %{
      "role" => "user",
      "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => "ok"}]
    }
  end

  describe "trim_orphan_tool_use/1" do
    test "keeps a window that already starts with a plain user message" do
      window = [user("hi"), assistant_text("hello"), user("how are you?")]
      assert trim_orphan_tool_use(window) == window
    end

    test "empty window stays empty" do
      assert trim_orphan_tool_use([]) == []
    end

    test "drops a leading orphaned tool_result (its tool_use fell off the window)" do
      # The assistant message left at the head is dropped too, since the API
      # requires the first message to be from the user.
      window = [tool_result("t1"), assistant_text("done"), user("thanks")]
      assert trim_orphan_tool_use(window) == [user("thanks")]

      assert trim_orphan_tool_use([tool_result("t1"), assistant_text("done")]) == []
    end

    test "drops a leading tool_use together with its matching tool_result" do
      window = [assistant_tool_use("t1"), tool_result("t1"), user("hi")]
      assert trim_orphan_tool_use(window) == [user("hi")]
    end

    test "drops a leading tool_use whose result never made the window" do
      window = [assistant_tool_use("t1"), user("hi")]
      assert trim_orphan_tool_use(window) == [user("hi")]
    end

    test "drops chained leading tool exchanges until a plain user message" do
      window = [
        assistant_tool_use("t1"),
        tool_result("t1"),
        assistant_tool_use("t2"),
        tool_result("t2"),
        user("hi")
      ]

      assert trim_orphan_tool_use(window) == [user("hi")]
    end

    test "drops a leading plain assistant message" do
      window = [assistant_text("hello"), user("hi")]
      assert trim_orphan_tool_use(window) == [user("hi")]
    end

    test "does not touch tool exchanges deeper in the window" do
      window = [user("hi"), assistant_tool_use("t1"), tool_result("t1"), assistant_text("done")]
      assert trim_orphan_tool_use(window) == window
    end
  end
end
