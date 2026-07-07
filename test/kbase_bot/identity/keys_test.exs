defmodule KbaseBot.Identity.KeysTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Identity.Keys

  @tag :tmp_dir
  test "generate/load roundtrip yields a working signing key", %{tmp_dir: dir} do
    path = Path.join(dir, "identity.json")

    assert {:ok, "sha256:" <> _} = Keys.generate_to(path)
    assert {:ok, {pub, priv}} = Keys.load(path)
    assert byte_size(pub) == 32

    msg = "roundtrip"
    sig = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519])
    assert :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])
    assert Keys.fingerprint(pub) == "sha256:" <> Base.encode16(:crypto.hash(:sha256, pub), case: :lower)
  end

  @tag :tmp_dir
  test "refuses to overwrite an existing identity", %{tmp_dir: dir} do
    path = Path.join(dir, "identity.json")
    assert {:ok, _} = Keys.generate_to(path)
    assert {:error, :already_exists} = Keys.generate_to(path)
  end

  @tag :tmp_dir
  test "load rejects malformed files", %{tmp_dir: dir} do
    path = Path.join(dir, "junk.json")
    File.write!(path, "not json")
    assert {:error, :invalid_key_file} = Keys.load(path)
  end
end
