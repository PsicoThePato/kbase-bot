defmodule KbaseBot.Federation.Contacts do
  @moduledoc """
  The owner-side address book: known peers and their current contact cards.
  Adding a contact grants *nothing* — grants and trust stay empty until the
  owner sets them.

  Key rotation lands here too: a card carrying a rotation proof from a
  contact we know migrates that contact — and everything keyed to it
  (grants re-issued, bindings, subscriptions, circles, open threads and
  exchanges, trust history) — to the new identity. The proof is checked
  against the pubkey we ALREADY store for the old id, never against key
  material the new card brought along.
  """

  alias KbaseBot.Federation.Card

  require Logger

  @doc """
  Verify and store a card. Existing contacts are only updated when the new
  card's `seq` is higher (monotonic convergence).
  """
  @spec add_card(map(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def add_card(card, notes \\ nil) do
    with {:ok, card} <- Card.verify(card) do
      principal_id = card["principal"]
      new_seq = card["seq"]
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      case find(principal_id) do
        {:ok, %{card_seq: stored_seq}} when stored_seq >= new_seq ->
          {:error, :stale_card}

        _ ->
          # Propagate store failures — "Contact added" with no row behind it
          # makes every later grant fail with "unknown contact".
          case KbaseBot.Repo.Store.execute(
                 """
                 INSERT OR REPLACE INTO contacts
                   (principal_id, display_name, card_json, card_seq, added_at, notes)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 """,
                 [
                   principal_id,
                   card["display_name"],
                   Jason.encode!(card),
                   card["seq"],
                   now,
                   notes
                 ]
               ) do
            :ok -> {:ok, principal_id}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @spec find(String.t()) :: {:ok, map()} | {:error, :not_found}
  def find(principal_id) do
    case KbaseBot.Repo.Store.query(
           "SELECT principal_id, display_name, card_json, card_seq, added_at, notes FROM contacts WHERE principal_id = ?1",
           [principal_id]
         ) do
      {:ok, [row | _]} -> {:ok, from_row(row)}
      _ -> {:error, :not_found}
    end
  end

  @doc "Raw Ed25519 public key for a stored contact — used to verify envelopes/records."
  @spec pubkey_for(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def pubkey_for(principal_id) do
    with {:ok, %{card: card}} <- find(principal_id),
         {:ok, pub} <- Card.pubkey(card) do
      {:ok, pub}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec list() :: [map()]
  def list do
    case KbaseBot.Repo.Store.query(
           "SELECT principal_id, display_name, card_json, card_seq, added_at, notes FROM contacts ORDER BY added_at"
         ) do
      {:ok, rows} -> Enum.map(rows, &from_row/1)
      _ -> []
    end
  end

  @doc """
  Apply a verified rotation card: migrate the old contact and everything
  keyed to its principal id to the new identity. Returns `{:ok, old_id}` on
  migration, `{:ok, :already_applied}` on an idempotent replay, an error
  otherwise. The caller is expected to have verified the card's signature
  and rotation-proof consistency (`Card.verify/1`); this function adds the
  one check only we can make — the proof's old key equals the STORED one.
  """
  @spec apply_rotation(map()) :: {:ok, String.t() | :already_applied} | {:error, term()}
  def apply_rotation(%{"rotation" => rotation} = card) when is_map(rotation) do
    with {:ok, card} <- Card.verify(card) do
      old_id = rotation["old"]
      new_id = card["principal"]

      case find(old_id) do
        {:error, :not_found} ->
          # Replay after a completed migration is fine; anything else is a
          # rotation from a stranger — no standing to migrate anything.
          case find(new_id) do
            {:ok, _} -> {:ok, :already_applied}
            _ -> {:error, :unknown_contact}
          end

        {:ok, stored} ->
          with {:ok, stored_pub} <- Card.pubkey(stored.card),
               {:ok, proof_pub} <- Base.decode64(rotation["old_pubkey"] || ""),
               true <- stored_pub == proof_pub || {:error, :old_key_mismatch},
               {:ok, ^new_id} <- add_card(card, stored.notes) do
            migrate_principal(old_id, new_id)

            KbaseBot.Repo.Store.execute("DELETE FROM contacts WHERE principal_id = ?1", [
              old_id
            ])

            {:ok, old_id}
          else
            {:error, reason} -> {:error, reason}
            _ -> {:error, :invalid_rotation}
          end
      end
    end
  end

  def apply_rotation(_), do: {:error, :invalid_rotation}

  # Everything keyed by principal id follows the rotation. Grants are the
  # one thing that can't be UPDATEd in place — a grant is a SIGNED record,
  # so each live one is re-issued to the new id and the old one revoked.
  defp migrate_principal(old_id, new_id) do
    alias KbaseBot.Federation.{Circles, Disclosures, Grants, TrustSignals}

    Grants.reissue(old_id, new_id)

    for {sql, params} <- [
          {"UPDATE OR IGNORE bindings SET principal_id = ?1 WHERE principal_id = ?2",
           [new_id, old_id]},
          {"DELETE FROM bindings WHERE principal_id = ?1", [old_id]},
          {"UPDATE OR IGNORE subscriptions SET principal_id = ?1 WHERE principal_id = ?2",
           [new_id, old_id]},
          {"DELETE FROM subscriptions WHERE principal_id = ?1", [old_id]},
          {"UPDATE threads SET principal_id = ?1 WHERE principal_id = ?2 AND state = 'open'",
           [new_id, old_id]},
          {"UPDATE exchanges SET peer = ?1 WHERE peer = ?2 AND state IN ('open', 'escalated')",
           [new_id, old_id]}
        ] do
      case KbaseBot.Repo.Store.execute(sql, params) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Rotation migration step failed: #{inspect(reason)}")
      end
    end

    Circles.rekey(old_id, new_id)
    TrustSignals.rekey(old_id, new_id)
    Disclosures.rekey(old_id, new_id)
    :ok
  end

  defp from_row([principal_id, display_name, card_json, card_seq, added_at, notes]) do
    %{
      principal_id: principal_id,
      display_name: display_name,
      card: Jason.decode!(card_json),
      card_seq: card_seq,
      added_at: added_at,
      notes: notes
    }
  end
end
