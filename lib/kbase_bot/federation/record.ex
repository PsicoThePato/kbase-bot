defmodule KbaseBot.Federation.Record do
  @moduledoc """
  Signed delegation record — the grant itself is the wire artifact:

      {v, iss, aud, scope, caps, caveats, issued_at, sig}

  `caps` is a map of capability name → `%{"depth" => n}` where depth is the
  number of further delegation edges allowed after this record (remaining
  hops, NOT distance from the owner; default 0 — not delegable). Records are
  plain string-keyed maps so they round-trip through canonical JSON unchanged.
  """

  alias KbaseBot.Federation.Canonical

  @capabilities ~w(query read subscribe discuss)

  @doc """
  Build an unsigned record. `caps` accepts the list sugar `["query"]`
  (all depth 0) or the full map form `%{"query" => %{"depth" => 2}}`.
  """
  @spec new(String.t(), String.t(), String.t(), list() | map(), map()) :: map()
  def new(iss, aud, scope, caps, caveats \\ %{}) do
    %{
      "v" => 1,
      "iss" => iss,
      "aud" => aud,
      "scope" => scope,
      "caps" => normalize_caps(caps),
      "caveats" => caveats,
      "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defdelegate sign(record, priv), to: Canonical
  defdelegate verified?(record, pub), to: Canonical

  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities

  @spec has_cap?(map(), String.t()) :: boolean()
  def has_cap?(record, capability), do: Map.has_key?(record["caps"] || %{}, capability)

  @doc "Remaining delegation hops for a capability (0 when absent)."
  @spec cap_depth(map(), String.t()) :: non_neg_integer()
  def cap_depth(record, capability) do
    get_in(record, ["caps", capability, "depth"]) || 0
  end

  @doc "Expiry check against `caveats.exp` (ISO8601). No exp ⇒ valid."
  @spec valid_now?(map(), DateTime.t()) :: boolean()
  def valid_now?(record, now \\ DateTime.utc_now()) do
    case get_in(record, ["caveats", "exp"]) do
      nil ->
        true

      exp when is_binary(exp) ->
        case DateTime.from_iso8601(exp) do
          {:ok, dt, _} -> DateTime.compare(now, dt) == :lt
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Does `child` legally attenuate `parent`? Same scope, chained principals
  (child.iss == parent.aud), caps a subset, every depth strictly smaller,
  and expiry never extended.
  """
  @spec attenuates?(map(), map()) :: boolean()
  def attenuates?(child, parent) do
    child["scope"] == parent["scope"] and
      child["iss"] == parent["aud"] and
      caps_attenuate?(child["caps"] || %{}, parent["caps"] || %{}) and
      exp_attenuates?(child, parent)
  end

  defp caps_attenuate?(child_caps, parent_caps) do
    Enum.all?(child_caps, fn {cap, %{"depth" => child_depth}} ->
      case parent_caps[cap] do
        %{"depth" => parent_depth} -> child_depth < parent_depth
        _ -> false
      end
    end)
  end

  defp exp_attenuates?(child, parent) do
    case {get_in(parent, ["caveats", "exp"]), get_in(child, ["caveats", "exp"])} do
      {nil, _} ->
        true

      {_parent_exp, nil} ->
        false

      {parent_exp, child_exp} ->
        with {:ok, p, _} <- DateTime.from_iso8601(parent_exp),
             {:ok, c, _} <- DateTime.from_iso8601(child_exp) do
          DateTime.compare(c, p) != :gt
        else
          _ -> false
        end
    end
  end

  defp normalize_caps(caps) when is_list(caps) do
    Map.new(caps, fn cap -> {to_string(cap), %{"depth" => 0}} end)
  end

  defp normalize_caps(caps) when is_map(caps) do
    Map.new(caps, fn
      {cap, %{"depth" => d}} when is_integer(d) and d >= 0 -> {to_string(cap), %{"depth" => d}}
      {cap, %{}} -> {to_string(cap), %{"depth" => 0}}
    end)
  end
end
