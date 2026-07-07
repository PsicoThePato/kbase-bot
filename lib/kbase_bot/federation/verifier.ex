defmodule KbaseBot.Federation.Verifier do
  @moduledoc """
  The one authorization mechanism: find a live path from the owner to the
  presenting principal covering (scope, capability), where every edge's
  per-capability depth covers the remaining path length.

  v1 is direct-only: `proof` must be `[]` and the path has length 1, found
  entirely in the live grants table. `anyone` is a reserved pseudo-principal:
  any verified principal matches an `anyone` grant. Chain verification is
  additive later; the depth arithmetic is already frozen here
  (`chain_depth_ok?/2`).
  """

  alias KbaseBot.Federation.{Grants, Record}

  @anyone "anyone"

  @doc "Reserved pseudo-principal for public grants."
  def anyone, do: @anyone

  @doc """
  Pure check over a list of live (non-revoked) grant records.
  Returns `{:ok, record}` or `{:error, :declined}` — deliberately
  indistinguishable between "no grant" and "no such scope".
  """
  @spec check([map()], String.t(), String.t(), String.t(), list(), DateTime.t()) ::
          {:ok, map()} | {:error, :declined}
  def check(grants, presenter_id, scope, capability, proof \\ [], now \\ DateTime.utc_now())

  def check(_grants, _presenter, _scope, _cap, proof, _now) when proof != [] do
    # Transitive access is out of v1: presented chains are declined.
    {:error, :declined}
  end

  def check(grants, presenter_id, scope, capability, [], now) do
    grants
    |> Enum.filter(fn r ->
      r["aud"] in [presenter_id, @anyone] and r["scope"] == scope
    end)
    |> Enum.filter(&Record.valid_now?(&1, now))
    |> Enum.find(&Record.has_cap?(&1, capability))
    |> case do
      nil -> {:error, :declined}
      record -> {:ok, record}
    end
  end

  @doc "DB-backed check against the live grants table."
  @spec authorize(String.t(), String.t(), String.t(), list()) ::
          {:ok, map()} | {:error, :declined}
  def authorize(presenter_id, scope, capability, proof \\ []) do
    check(Grants.all_live(), presenter_id, scope, capability, proof)
  end

  @doc """
  Depth arithmetic over an ordered delegation chain (edge 1 = the owner's
  own grant, last edge reaches the presenter): the record on edge i must
  carry `depth >= L - i` for the exercised capability, and each attenuated
  record must carry a strictly smaller depth than its parent. Pure —
  unused by v1 authorization, but frozen now so chains are additive.
  """
  @spec chain_depth_ok?([map()], String.t()) :: boolean()
  def chain_depth_ok?(records, capability) when is_list(records) and records != [] do
    l = length(records)

    depths_cover_remaining? =
      records
      |> Enum.with_index(1)
      |> Enum.all?(fn {r, i} -> Record.cap_depth(r, capability) >= l - i end)

    strictly_decreasing? =
      records
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [parent, child] ->
        Record.cap_depth(child, capability) < Record.cap_depth(parent, capability)
      end)

    depths_cover_remaining? and strictly_decreasing?
  end

  def chain_depth_ok?(_, _), do: false
end
