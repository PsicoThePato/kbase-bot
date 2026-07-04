defmodule KbaseBot.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Tools.Registry

  describe "find_tool/1" do
    test "resolves a registered tool by its name" do
      name = KbaseBot.Tools.GetCurrentTime.name()
      assert Registry.find_tool(name) == KbaseBot.Tools.GetCurrentTime
    end

    test "returns nil for unknown names" do
      assert Registry.find_tool("definitely_not_a_tool") == nil
    end
  end

  describe "execute/3" do
    test "dispatches to the tool module" do
      assert {:ok, result} = Registry.execute("get_current_time", %{})
      assert result =~ "BRT"
    end

    test "returns an error for unknown tools" do
      assert Registry.execute("nope", %{}) == {:error, "unknown tool: nope"}
    end
  end

  describe "for_layer/1" do
    test "returns Anthropic-format schemas for the layer" do
      schemas = Registry.for_layer(:manager)
      assert schemas != []

      for schema <- schemas do
        assert is_binary(schema.name)
        assert is_binary(schema.description)
        assert is_map(schema.input_schema)
      end
    end

    test "layer :both tools appear in both layers" do
      name = KbaseBot.Tools.GetCurrentTime.name()
      assert Enum.any?(Registry.for_layer(:manager), &(&1.name == name))
      assert Enum.any?(Registry.for_layer(:task), &(&1.name == name))
    end
  end
end
