defmodule KbaseBot.Principal do
  @moduledoc """
  A stable identity for a person-or-agent pair (see docs/multiplayer-federation.md).

  The owner is a principal too — the superuser. Until keypair identity lands,
  the owner id is a local sentinel; grants and trust attach to `id`, never to
  transport details, so the sentinel can be swapped for a key fingerprint
  without touching call sites (always go through `owner?/1`).
  """

  @owner_id "owner"

  defstruct [:id, :provider, :display_name, meta: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          display_name: String.t() | nil,
          meta: map()
        }

  @spec owner() :: t()
  def owner do
    %__MODULE__{id: @owner_id, provider: :local, display_name: "owner"}
  end

  @spec owner?(term()) :: boolean()
  def owner?(%__MODULE__{id: @owner_id}), do: true
  def owner?(_), do: false
end
