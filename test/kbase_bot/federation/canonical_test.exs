defmodule KbaseBot.Federation.CanonicalTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Federation.Canonical

  test "sorts keys recursively with no whitespace" do
    assert Canonical.encode!(%{"b" => 1, "a" => %{"z" => true, "y" => nil}}) ==
             ~s({"a":{"y":null,"z":true},"b":1})
  end

  test "atom and string keys canonicalize identically" do
    assert Canonical.encode!(%{b: 1, a: 2}) == Canonical.encode!(%{"a" => 2, "b" => 1})
  end

  test "lists preserve order" do
    assert Canonical.encode!(%{"l" => [3, 1, 2]}) == ~s({"l":[3,1,2]})
  end

  test "unicode strings round-trip through Jason escaping" do
    encoded = Canonical.encode!(%{"name" => "Jairo Môutinho — teste"})
    assert Jason.decode!(encoded) == %{"name" => "Jairo Môutinho — teste"}
  end

  test "floats are forbidden" do
    assert_raise ArgumentError, fn -> Canonical.encode!(%{"score" => 0.5}) end
    assert_raise ArgumentError, fn -> Canonical.encode!(%{"deep" => %{"x" => [1.0]}}) end
  end

  test "signing_bytes excludes the sig field" do
    with_sig = %{"a" => 1, "sig" => "xxx"}
    without = %{"a" => 1}
    assert Canonical.signing_bytes(with_sig) == Canonical.encode!(without)
  end

  test "sign/verified? roundtrip and tamper detection" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    signed = Canonical.sign(%{"msg" => "hello", "n" => 42}, priv)

    assert Canonical.verified?(signed, pub)
    refute Canonical.verified?(Map.put(signed, "n", 43), pub)
    refute Canonical.verified?(Map.put(signed, "sig", Base.encode64("junk")), pub)

    {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
    refute Canonical.verified?(signed, other_pub)
  end
end
