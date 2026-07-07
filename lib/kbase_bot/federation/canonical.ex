defmodule KbaseBot.Federation.Canonical do
  @moduledoc """
  Deterministic JSON for signing: recursive key sort, no whitespace, UTF-8.

  Floats are forbidden in signed payloads (their serialization is not
  portable across implementations) — ints, strings, booleans, nil, lists and
  maps only. Signatures are Ed25519 over the canonical bytes of the object
  minus its `sig` field, base64-encoded.
  """

  @doc "Canonical JSON encoding of a term. Raises on floats."
  @spec encode!(term()) :: binary()
  def encode!(term), do: IO.iodata_to_binary(enc(term))

  @doc "The bytes a signature covers: the object without its sig field."
  @spec signing_bytes(map()) :: binary()
  def signing_bytes(map) when is_map(map) do
    map |> Map.drop(["sig", :sig]) |> encode!()
  end

  @doc "Sign a map with an Ed25519 private key; returns the map with \"sig\" set."
  @spec sign(map(), binary()) :: map()
  def sign(map, priv) when is_map(map) do
    sig = :crypto.sign(:eddsa, :none, signing_bytes(map), [priv, :ed25519])
    Map.put(map, "sig", Base.encode64(sig))
  end

  @doc "Verify a map's \"sig\" against an Ed25519 public key."
  @spec verified?(map(), binary()) :: boolean()
  def verified?(map, pub) when is_map(map) do
    with sig_b64 when is_binary(sig_b64) <- map["sig"],
         {:ok, sig} <- Base.decode64(sig_b64) do
      :crypto.verify(:eddsa, :none, signing_bytes(map), sig, [pub, :ed25519])
    else
      _ -> false
    end
  end

  # --- encoding ---

  defp enc(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {key!(k), v} end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", enc(v)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp enc(list) when is_list(list) do
    ["[", list |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]
  end

  defp enc(f) when is_float(f) do
    raise ArgumentError, "floats are forbidden in signed payloads, got: #{inspect(f)}"
  end

  defp enc(other), do: Jason.encode!(other)

  defp key!(k) when is_binary(k), do: k
  defp key!(k) when is_atom(k), do: Atom.to_string(k)
end
