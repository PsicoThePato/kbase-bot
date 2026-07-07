defmodule KbaseBot.Federation.Grants do
  @moduledoc """
  Owner-authored delegation records — the live grant graph's root edges.
  The grants table IS the source of truth: revocation is a `revoked_at`
  stamp, and every authorization check reads live rows.
  """

  alias KbaseBot.Federation.Record
  alias KbaseBot.Identity.Keys
  alias KbaseBot.Policy.Scopes

  @doc """
  Create, sign and persist a grant (iss = own principal). Rejects
  non-grantable scopes (`private`, `medical`, ...) for any audience,
  including `anyone`.
  """
  @spec create(String.t(), String.t(), list() | map(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def create(aud, scope, caps, caveats \\ %{}) do
    cond do
      scope in Scopes.non_grantable() ->
        {:error, "scope #{scope} is non-grantable"}

      not caps_known?(caps) ->
        {:error, "unknown capability (known: #{Enum.join(Record.capabilities(), ", ")})"}

      true ->
        with {:ok, {_pub, priv}} <- Keys.own_keypair(),
             {:ok, iss} <- Keys.own_principal_id() do
          record = Record.new(iss, aud, scope, caps, caveats) |> Record.sign(priv)
          id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          KbaseBot.Repo.Store.execute(
            """
            INSERT INTO grants (id, aud, scope, caps_json, caveats_json, record_json, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            [
              id,
              aud,
              scope,
              Jason.encode!(record["caps"]),
              Jason.encode!(record["caveats"]),
              Jason.encode!(record),
              now
            ]
          )

          {:ok, id}
        end
    end
  end

  @doc "All live (non-revoked) grant records. Expiry is checked by the Verifier."
  @spec all_live() :: [map()]
  def all_live do
    case KbaseBot.Repo.Store.query(
           "SELECT record_json FROM grants WHERE revoked_at IS NULL"
         ) do
      {:ok, rows} -> Enum.map(rows, fn [json] -> Jason.decode!(json) end)
      _ -> []
    end
  end

  @doc "Live grants whose audience is `aud` or `anyone`."
  @spec live_for(String.t()) :: [map()]
  def live_for(aud) do
    Enum.filter(all_live(), fn r -> r["aud"] in [aud, "anyone"] end)
  end

  @doc "Revoke by grant id — severs everyone downstream instantly."
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case KbaseBot.Repo.Store.query(
           "SELECT id FROM grants WHERE id = ?1 AND revoked_at IS NULL",
           [id]
         ) do
      {:ok, [_row | _]} ->
        KbaseBot.Repo.Store.execute(
          "UPDATE grants SET revoked_at = ?1 WHERE id = ?2",
          [now, id]
        )

        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Does a live, unexpired grant give `principal_id` any of `caps` on `scope`?"
  @spec covers?(String.t(), String.t(), [String.t()]) :: boolean()
  def covers?(principal_id, scope, caps) when is_list(caps) do
    now = DateTime.utc_now()

    live_for(principal_id)
    |> Enum.filter(fn r -> r["scope"] == scope end)
    |> Enum.filter(&Record.valid_now?(&1, now))
    |> Enum.any?(fn r -> Enum.any?(caps, &Record.has_cap?(r, &1)) end)
  end

  @doc "Scopes on which `principal_id` holds at least one live grant (grant-gated visibility)."
  @spec granted_scopes(String.t()) :: [String.t()]
  def granted_scopes(principal_id) do
    now = DateTime.utc_now()

    live_for(principal_id)
    |> Enum.filter(&Record.valid_now?(&1, now))
    |> Enum.map(& &1["scope"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "All rows for owner display: {id, aud, scope, caps, created_at, revoked_at}."
  @spec list() :: [map()]
  def list do
    case KbaseBot.Repo.Store.query(
           "SELECT id, aud, scope, caps_json, created_at, revoked_at FROM grants ORDER BY created_at"
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, aud, scope, caps_json, created_at, revoked_at] ->
          %{
            id: id,
            aud: aud,
            scope: scope,
            caps: Jason.decode!(caps_json),
            created_at: created_at,
            revoked_at: revoked_at
          }
        end)

      _ ->
        []
    end
  end

  defp caps_known?(caps) when is_list(caps) do
    Enum.all?(caps, &(to_string(&1) in Record.capabilities()))
  end

  defp caps_known?(caps) when is_map(caps) do
    Enum.all?(Map.keys(caps), &(to_string(&1) in Record.capabilities()))
  end
end
