defmodule KbaseBot.Tool do
  @moduledoc """
  Behaviour for all tools in the system.
  Each tool declares which layer it belongs to (:manager, :task, or :both).
  """

  @type layer :: :manager | :task | :both
  @type tool_result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback layer() :: layer()
  @callback execute(input :: map(), context :: map()) :: tool_result()

  @doc """
  Owner assertion for privileged (state-mutating) tools — the capability
  ceiling, enforced in code: a missing or non-owner principal fails closed,
  so a routing bug can never expose these tools to a peer.
  """
  @spec require_owner(map()) :: :ok | {:error, String.t()}
  def require_owner(context) do
    if KbaseBot.Principal.owner?(context[:principal]) do
      :ok
    else
      {:error, "forbidden: owner-only tool"}
    end
  end
end
