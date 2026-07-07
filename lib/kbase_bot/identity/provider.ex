defmodule KbaseBot.Identity.Provider do
  @moduledoc """
  Behaviour for identity providers: how a peer proves who they are is
  decoupled from everything else. Providers mint Principals; grants and trust
  attach to `Principal.id`, never to transport details.
  """

  @callback id() :: atom()
  @callback verify(assertion :: term()) ::
              {:ok, KbaseBot.Principal.t()} | {:error, term()}
end
