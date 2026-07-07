defmodule KbaseBot.Federation.Envelope do
  @moduledoc """
  Signed JSON envelopes, independent of transport. Correlation is by `id`,
  never by connection — an ANSWER arriving hours later over a different pipe
  is the same exchange. Unknown kinds are declined, not crashed (open enum).
  """

  alias KbaseBot.Federation.Canonical
  alias KbaseBot.Identity.Keys

  @kinds ~w(QUERY ANSWER DECLINE ESCALATED LIST-SCOPES SCOPES CARD-UPDATE)

  def kinds, do: @kinds

  def known_kind?(kind), do: kind in @kinds

  @doc "Build and sign an envelope from this bot's identity."
  @spec build(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def build(kind, fields) when is_map(fields) do
    with {:ok, {_pub, priv}} <- Keys.own_keypair(),
         {:ok, from} <- Keys.own_principal_id() do
      envelope =
        Map.merge(fields, %{
          "v" => 1,
          "kind" => kind,
          "id" => Map.get(fields, "id", new_id()),
          "from" => from
        })

      {:ok, Canonical.sign(envelope, priv)}
    end
  end

  @doc "Fresh envelope id."
  def new_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
