defmodule KbaseBot.PolicyTest do
  use ExUnit.Case, async: true

  alias KbaseBot.{Policy, Principal}

  @peer %Principal{id: "sha256:abc", provider: :ed25519, display_name: "Alice"}

  test "owner can read everything" do
    assert Policy.can_read_file?(Principal.owner(), "x.md", "---\nscopes: [private]\n---\n")
  end

  test "non-owner principals are denied by default" do
    refute Policy.can_read_file?(@peer, "x.md", "unlabeled content")
  end

  test "missing principal fails closed" do
    refute Policy.can_read_file?(nil, "x.md", "content")
  end

  test "require_owner enforces the capability ceiling fail-closed" do
    assert KbaseBot.Tool.require_owner(%{principal: Principal.owner()}) == :ok
    assert {:error, _} = KbaseBot.Tool.require_owner(%{principal: @peer})
    assert {:error, _} = KbaseBot.Tool.require_owner(%{})
  end
end
