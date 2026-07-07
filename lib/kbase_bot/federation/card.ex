defmodule KbaseBot.Federation.Card do
  @moduledoc """
  Contact card: a signed, versioned document a peer authors about itself.
  Because it is self-signed it can be relayed through any channel. Cards
  carry the raw public key (base64) — the principal id is its fingerprint,
  and verification checks both the binding and the signature.
  """

  alias KbaseBot.Federation.Canonical
  alias KbaseBot.Identity.Keys

  @doc "Build and sign this bot's own card."
  @spec build(String.t(), non_neg_integer(), [map()], [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def build(display_name, seq, endpoints, public_scopes \\ []) do
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

      {:ok, Canonical.sign(card, priv)}
    end
  end

  @doc """
  Verify a card: pubkey present, principal id is its fingerprint, signature
  valid. Returns `{:ok, card}` or `{:error, :invalid_card}`.
  """
  @spec verify(map()) :: {:ok, map()} | {:error, :invalid_card}
  def verify(%{"principal" => principal, "pubkey" => pub_b64} = card) do
    with {:ok, pub} <- Base.decode64(pub_b64),
         true <- byte_size(pub) == 32,
         true <- Keys.fingerprint(pub) == principal,
         true <- Canonical.verified?(card, pub) do
      {:ok, card}
    else
      _ -> {:error, :invalid_card}
    end
  end

  def verify(_), do: {:error, :invalid_card}

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
