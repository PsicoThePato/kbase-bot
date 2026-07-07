defmodule KbaseBot.Federation.Card do
  @moduledoc """
  Contact card: a signed, versioned document a peer authors about itself.
  Because it is self-signed it can be relayed through any channel. Cards
  carry the raw public key (base64) — the principal id is its fingerprint,
  and verification checks both the binding and the signature.

  A card may carry a `rotation` proof: the previous key signing the
  statement that this card's key succeeds it. Verification here is
  self-contained (the proof is internally consistent and signed by the old
  key it names); the binding that matters — that the old key is one WE
  actually know — is checked by `Contacts.apply_rotation/1` against the
  stored card, never against bytes the new card brought along.
  """

  alias KbaseBot.Federation.Canonical
  alias KbaseBot.Identity.Keys

  @doc """
  Build and sign this bot's own card. `rotation` (optional) is a signed
  rotation proof binding a previous identity to this one — included whenever
  the bot has rotated keys, so even a manually re-shared card migrates peers.
  """
  @spec build(String.t(), non_neg_integer(), [map()], [String.t()], map() | nil) ::
          {:ok, map()} | {:error, term()}
  def build(display_name, seq, endpoints, public_scopes \\ [], rotation \\ nil) do
    with {:ok, {pub, priv}} <- Keys.own_keypair() do
      card = %{
        "v" => 1,
        "principal" => Keys.fingerprint(pub),
        "pubkey" => Base.encode64(pub),
        "display_name" => display_name,
        "seq" => seq,
        "identity_providers" => ["ed25519"],
        "endpoints" => endpoints,
        "scopes" => public_scopes
      }

      card = if rotation, do: Map.put(card, "rotation", rotation), else: card

      {:ok, Canonical.sign(card, priv)}
    end
  end

  @doc """
  Author a rotation proof: the OLD key signs the statement that the new key
  succeeds it.
  """
  @spec rotation_proof(binary(), binary(), binary()) :: map()
  def rotation_proof(old_pub, old_priv, new_pub) do
    Canonical.sign(
      %{
        "v" => 1,
        "old" => Keys.fingerprint(old_pub),
        "old_pubkey" => Base.encode64(old_pub),
        "new" => Keys.fingerprint(new_pub),
        "new_pubkey" => Base.encode64(new_pub)
      },
      old_priv
    )
  end

  @doc """
  Verify a card: pubkey present, principal id is its fingerprint, signature
  valid, `seq` a non-negative integer (monotonic convergence depends on it).
  A card carrying a malformed or mis-signed rotation proof is invalid as a
  whole (fail closed). Returns `{:ok, card}` or `{:error, :invalid_card}`.
  """
  @spec verify(map()) :: {:ok, map()} | {:error, :invalid_card}
  def verify(%{"principal" => principal, "pubkey" => pub_b64} = card) do
    with seq when is_integer(seq) and seq >= 0 <- card["seq"],
         {:ok, pub} <- Base.decode64(pub_b64),
         true <- byte_size(pub) == 32,
         true <- Keys.fingerprint(pub) == principal,
         true <- Canonical.verified?(card, pub),
         true <- rotation_consistent?(card) do
      {:ok, card}
    else
      _ -> {:error, :invalid_card}
    end
  end

  def verify(_), do: {:error, :invalid_card}

  # The proof must name THIS card's identity as the successor and be signed
  # by the old key it names. (Whether that old key is trusted is Contacts'
  # call — it compares against the pubkey it already stores.)
  defp rotation_consistent?(%{"rotation" => rotation} = card) when is_map(rotation) do
    with new when is_binary(new) <- rotation["new"],
         true <- new == card["principal"],
         true <- rotation["new_pubkey"] == card["pubkey"],
         {:ok, old_pub} <- Base.decode64(rotation["old_pubkey"] || ""),
         true <- byte_size(old_pub) == 32,
         true <- Keys.fingerprint(old_pub) == rotation["old"],
         true <- rotation["old"] != card["principal"] do
      Canonical.verified?(rotation, old_pub)
    else
      _ -> false
    end
  end

  defp rotation_consistent?(%{"rotation" => _}), do: false
  defp rotation_consistent?(_), do: true

  @doc "Raw public key from a (verified) card."
  @spec pubkey(map()) :: {:ok, binary()} | :error
  def pubkey(%{"pubkey" => pub_b64}) do
    case Base.decode64(pub_b64) do
      {:ok, pub} -> {:ok, pub}
      _ -> :error
    end
  end

  def pubkey(_), do: :error
end
