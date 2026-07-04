defmodule KbaseBot.Tasks.Commands do
  @moduledoc """
  Task command types. Simplified from aifred-web's TaskCommandType.
  """

  @type t :: :follow_up | :cancel | :approve
end
