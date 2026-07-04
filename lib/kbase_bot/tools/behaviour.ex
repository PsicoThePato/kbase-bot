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
end
