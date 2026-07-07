defmodule KbaseBot.Identity.Ed25519 do
  @moduledoc """
  Keypair identity: a peer *is* their Ed25519 public key. The assertion is a
  map carrying `"pubkey"` (base64 raw key); the minted principal id is the
  key's sha256 fingerprint. Signature checks happen wherever the signed
  object is handled (`Federation.Canonical.verified?/2`).
  """

  @behaviour KbaseBot.Identity.Provider

  alias KbaseBot.{Identity.Keys, Principal}

  @impl true
  def id, do: :ed25519

  @impl true
  def verify(%{"pubkey" => pub_b64} = assertion) do
    case Base.decode64(pub_b64) do
      {:ok, pub} when byte_size(pub) == 32 ->
        {:ok,
         %Principal{
           id: Keys.fingerprint(pub),
           provider: :ed25519,
           display_name: assertion["display_name"],
           meta: %{pubkey: pub}
         }}

      _ ->
        {:error, :invalid_pubkey}
    end
  end

  def verify(_), do: {:error, :invalid_assertion}
end
