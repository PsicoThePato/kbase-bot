defmodule KbaseBot.Federation.Contacts do
  @moduledoc """
  The owner-side address book: known peers and their current contact cards.
  Adding a contact grants *nothing* — grants and trust stay empty until the
  owner sets them.
  """

  alias KbaseBot.Federation.Card

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
          KbaseBot.Repo.Store.execute(
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
          )

          {:ok, principal_id}
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
