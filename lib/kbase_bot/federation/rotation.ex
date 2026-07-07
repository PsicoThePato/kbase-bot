defmodule KbaseBot.Federation.Rotation do
  @moduledoc """
  Rotate this bot's own federation identity: generate a fresh Ed25519
  keypair, have the OLD key sign a rotation proof binding it to the new one,
  re-sign our own live grant records, and broadcast a rotation card to every
  contact as CARD-UPDATE (queued for offline peers — store-and-forward makes
  the broadcast survive their downtime).

  The proof is persisted inside the key file and rides on every card we
  build from then on, so even a peer who missed the broadcast migrates the
  moment they see any card of ours. Single-hop only: a peer two rotations
  behind needs a manual re-add — chain proofs are a later protocol addition.

  A rotation is only as trustworthy as the old key at the moment of signing:
  rotate BEFORE a suspected compromise becomes a certain one. A key an
  attacker already holds can sign them a rotation just as well.
  """

  alias KbaseBot.Federation.{Card, Contacts, Envelope, Grants, Outbound, Record}
  alias KbaseBot.Identity.Keys
  alias KbaseBot.Repo.Store

  require Logger

  @doc """
  Perform the rotation. Returns `{:ok, %{old_id, new_id, notified}}`.
  """
  @spec rotate_own() :: {:ok, map()} | {:error, term()}
  def rotate_own do
    with path when is_binary(path) <- key_path() || {:error, :no_identity},
         {:ok, {old_pub, old_priv}} <- Keys.own_keypair() do
      old_id = Keys.fingerprint(old_pub)
      {new_pub, new_priv} = :crypto.generate_key(:eddsa, :ed25519)
      new_id = Keys.fingerprint(new_pub)
      rotation = Card.rotation_proof(old_pub, old_priv, new_pub)

      with :ok <- persist_keys(path, new_pub, new_priv, rotation) do
        Keys.reset_cache()
        resign_own_grants(new_id, new_priv)
        notified = broadcast(rotation)

        {:ok, %{old_id: old_id, new_id: new_id, notified: notified}}
      end
    else
      nil -> {:error, :no_identity}
      err -> err
    end
  end

  @doc "The persisted rotation proof from the key file, if this identity ever rotated."
  @spec proof() :: map() | nil
  def proof do
    with path when is_binary(path) <- key_path(),
         {:ok, raw} <- File.read(path),
         {:ok, %{"rotation" => rotation}} when is_map(rotation) <- Jason.decode(raw) do
      rotation
    else
      _ -> nil
    end
  end

  # Backup-then-write: the old key file survives as *.pre-rotation-<ts> so a
  # botched rotation is recoverable by hand.
  defp persist_keys(path, new_pub, new_priv, rotation) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")

    with :ok <- File.rename(path, path <> ".pre-rotation-" <> ts) do
      json =
        Jason.encode!(%{
          "ed25519_pub" => Base.encode64(new_pub),
          "ed25519_priv" => Base.encode64(new_priv),
          "rotation" => rotation
        })

      File.write!(path, json)
      File.chmod!(path, 0o600)
      :ok
    end
  end

  # Our live grant records carry iss = the old id, signed by the old key.
  # v1 authorization never checks them (the live table is trusted), but
  # future chain verification will — re-sign in place, same ids and caveats.
  defp resign_own_grants(new_id, new_priv) do
    case Store.query("SELECT id, record_json FROM grants WHERE revoked_at IS NULL") do
      {:ok, rows} ->
        Enum.each(rows, fn [id, record_json] ->
          old = Jason.decode!(record_json)

          fresh =
            Record.new(new_id, old["aud"], old["scope"], old["caps"], old["caveats"] || %{})
            |> Record.sign(new_priv)

          Store.execute("UPDATE grants SET record_json = ?1 WHERE id = ?2", [
            Jason.encode!(fresh),
            id
          ])
        end)

      _ ->
        :ok
    end
  end

  defp broadcast(rotation) do
    endpoints = own_endpoints()
    display_name = Application.get_env(:kbase_bot, :federation_display_name, "KbaseBot")
    public_scopes = Grants.granted_scopes(KbaseBot.Federation.Verifier.anyone())

    with {:ok, card} <-
           Card.build(display_name, System.os_time(:second), endpoints, public_scopes, rotation) do
      Contacts.list()
      |> Enum.count(fn contact ->
        case Envelope.build("CARD-UPDATE", %{"to" => contact.principal_id, "card" => card}) do
          {:ok, envelope} -> Outbound.deliver(envelope, contact.principal_id) == :ok
          _ -> false
        end
      end)
    else
      _ -> 0
    end
  end

  defp own_endpoints do
    case Application.get_env(:kbase_bot, :federation_public_url) do
      nil ->
        []

      url ->
        [
          %{
            "transport" => "https",
            "address" => String.trim_trailing(url, "/") <> "/federation/inbox",
            "priority" => 1
          }
        ]
    end
  end

  defp key_path, do: Application.get_env(:kbase_bot, :federation_key_path)
end
