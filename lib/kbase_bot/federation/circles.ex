defmodule KbaseBot.Federation.Circles do
  @moduledoc """
  Owner-local peer groups ("friends", "gym"). Purely an address-book
  convenience: granting to `circle:<name>` expands to one ordinary signed
  grant per member at grant time, so nothing about circles ever crosses the
  wire and the live grant table stays the only authorization truth. A peer
  added later gets nothing retroactively — grants are per-member snapshots.
  """

  alias KbaseBot.Federation.Contacts
  alias KbaseBot.Repo.Store

  @prefix "circle:"

  @doc "Is this principal-id argument a circle reference?"
  @spec ref?(String.t()) :: boolean()
  def ref?(id) when is_binary(id), do: String.starts_with?(id, @prefix)
  def ref?(_), do: false

  @doc "The circle name inside a `circle:<name>` reference."
  @spec ref_name(String.t()) :: String.t()
  def ref_name(@prefix <> name), do: name

  @doc "Add a known contact to a circle (creates the circle implicitly)."
  @spec add(String.t(), String.t()) :: :ok | {:error, term()}
  def add(name, principal_id) do
    with {:ok, name} <- valid_name(name),
         {:ok, _} <- Contacts.find(principal_id) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Store.execute(
        "INSERT OR IGNORE INTO circles (name, principal_id, added_at) VALUES (?1, ?2, ?3)",
        [name, principal_id, now]
      )

      :ok
    else
      {:error, :not_found} -> {:error, :unknown_contact}
      err -> err
    end
  end

  @spec remove(String.t(), String.t()) :: :ok
  def remove(name, principal_id) do
    Store.execute("DELETE FROM circles WHERE name = ?1 AND principal_id = ?2", [
      name,
      principal_id
    ])

    :ok
  end

  @doc "Member principal ids of a circle."
  @spec members(String.t()) :: [String.t()]
  def members(name) do
    case Store.query(
           "SELECT principal_id FROM circles WHERE name = ?1 ORDER BY added_at",
           [name]
         ) do
      {:ok, rows} -> Enum.map(rows, fn [id] -> id end)
      _ -> []
    end
  end

  @doc "All circles with their members."
  @spec list() :: %{String.t() => [String.t()]}
  def list do
    case Store.query("SELECT name, principal_id FROM circles ORDER BY name, added_at") do
      {:ok, rows} ->
        Enum.group_by(rows, fn [name, _] -> name end, fn [_, id] -> id end)

      _ ->
        %{}
    end
  end

  @doc "Re-key memberships to a rotated principal id."
  @spec rekey(String.t(), String.t()) :: :ok
  def rekey(old_id, new_id) do
    Store.execute("UPDATE OR IGNORE circles SET principal_id = ?1 WHERE principal_id = ?2", [
      new_id,
      old_id
    ])

    Store.execute("DELETE FROM circles WHERE principal_id = ?1", [old_id])
    :ok
  end

  # A circle name must never collide with a principal id or the `anyone`
  # pseudo-principal when written as `circle:<name>` — keep it a plain slug.
  defp valid_name(name) when is_binary(name) do
    if Regex.match?(~r/^[a-z0-9_-]{1,32}$/, name) do
      {:ok, name}
    else
      {:error, "circle names are lowercase slugs (a-z, 0-9, -, _), max 32 chars"}
    end
  end

  defp valid_name(_), do: {:error, "circle names are lowercase slugs"}
end
