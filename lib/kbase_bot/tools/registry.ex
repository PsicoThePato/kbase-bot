defmodule KbaseBot.Tools.Registry do
  @moduledoc """
  Compile-time tool collection and runtime dispatch.
  Inspired by aifred-web's register_tools! macro pattern.
  """

  @tools [
    KbaseBot.Tools.Respond,
    KbaseBot.Tools.GetCurrentTime,
    KbaseBot.Tools.JournalEntry,
    KbaseBot.Tools.RefreshContext,
    KbaseBot.Tools.SpawnTask,
    KbaseBot.Tools.ListActiveTasks,
    KbaseBot.Tools.ReadTaskDetails,
    KbaseBot.Tools.MessageTask,
    KbaseBot.Tools.CancelTask,
    KbaseBot.Tools.CreateSchedule,
    KbaseBot.Tools.ListSchedules,
    KbaseBot.Tools.CancelSchedule,
    KbaseBot.Tools.UpdateSchedule,
    KbaseBot.Tools.SearchKnowledge,
    KbaseBot.Tools.ReadFile,
    KbaseBot.Tools.ListFiles,
    KbaseBot.Tools.NotifyUser,
    KbaseBot.Tools.SendGif,
    KbaseBot.Tools.RequestTool,
    KbaseBot.Tools.SearchHistory,
    KbaseBot.Tools.SearchTasks,
    KbaseBot.Tools.WebSearch,
    KbaseBot.Tools.CreateTodo,
    KbaseBot.Tools.ListTodos,
    KbaseBot.Tools.CompleteTodo,
    KbaseBot.Tools.DeleteTodo,
    # Federation — owner-facing manager tools
    KbaseBot.Tools.ShowFederationCard,
    KbaseBot.Tools.AddContact,
    KbaseBot.Tools.ListContacts,
    KbaseBot.Tools.GrantScope,
    KbaseBot.Tools.RevokeGrant,
    KbaseBot.Tools.ListGrants,
    KbaseBot.Tools.QueryPeer,
    KbaseBot.Tools.ListPeerScopes,
    KbaseBot.Tools.AnswerEscalation,
    KbaseBot.Tools.BindTopic,
    KbaseBot.Tools.UnbindTopic,
    KbaseBot.Tools.ListBindings,
    KbaseBot.Tools.SubscribePeer,
    KbaseBot.Tools.UnsubscribePeer,
    KbaseBot.Tools.ListSubscriptions,
    KbaseBot.Tools.PublishItem,
    KbaseBot.Tools.DiscussPeer,
    # Federation — constrained-loop tools (layer :federation, never in
    # manager/task loops; reachable only via an explicit Session toolset)
    KbaseBot.Tools.AnswerPeer,
    KbaseBot.Tools.DeclinePeer,
    KbaseBot.Tools.EscalateToOwner,
    KbaseBot.Tools.InboxAppend,
    KbaseBot.Tools.Say,
    KbaseBot.Tools.CloseThread
  ]

  @federation_tools [
    KbaseBot.Tools.ShowFederationCard,
    KbaseBot.Tools.AddContact,
    KbaseBot.Tools.ListContacts,
    KbaseBot.Tools.GrantScope,
    KbaseBot.Tools.RevokeGrant,
    KbaseBot.Tools.ListGrants,
    KbaseBot.Tools.QueryPeer,
    KbaseBot.Tools.ListPeerScopes,
    KbaseBot.Tools.AnswerEscalation,
    KbaseBot.Tools.BindTopic,
    KbaseBot.Tools.UnbindTopic,
    KbaseBot.Tools.ListBindings,
    KbaseBot.Tools.SubscribePeer,
    KbaseBot.Tools.UnsubscribePeer,
    KbaseBot.Tools.ListSubscriptions,
    KbaseBot.Tools.PublishItem,
    KbaseBot.Tools.DiscussPeer
  ]

  @required_config Map.merge(
                     %{
                       KbaseBot.Tools.SendGif => :giphy_api_key,
                       KbaseBot.Tools.WebSearch => :exa_api_key,
                       KbaseBot.Tools.CreateTodo => :todoist_api_key,
                       KbaseBot.Tools.ListTodos => :todoist_api_key,
                       KbaseBot.Tools.CompleteTodo => :todoist_api_key,
                       KbaseBot.Tools.DeleteTodo => :todoist_api_key,
                       KbaseBot.Tools.SearchHistory => :voyage_api_key,
                       KbaseBot.Tools.SearchTasks => :voyage_api_key
                     },
                     Map.new(@federation_tools, &{&1, :federation_key_path})
                   )

  @doc """
  Returns Anthropic-format tool schemas for a given layer. Tools whose
  backing integration is unconfigured are omitted.
  """
  def for_layer(layer) do
    @tools
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :layer, 0) and
        mod.layer() in [layer, :both] and configured?(mod)
    end)
    |> Enum.map(&tool_schema/1)
  end

  defp configured?(mod) do
    case @required_config[mod] do
      nil -> true
      key -> Application.get_env(:kbase_bot, key) not in [nil, ""]
    end
  end

  @doc """
  Execute a tool by name with the given input and context.
  """
  def execute(name, input, context \\ %{}) do
    case find_tool(name) do
      nil -> {:error, "unknown tool: #{name}"}
      mod -> mod.execute(input, context)
    end
  end

  @doc """
  Find a tool module by name.
  """
  def find_tool(name) do
    Enum.find(@tools, fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0) and
        mod.name() == name
    end)
  end

  @doc """
  Anthropic-format schema for one tool module — used by loops with an
  explicit toolset (federation responder) instead of layer filtering.
  """
  def tool_schema(mod) do
    %{
      name: mod.name(),
      description: mod.description(),
      input_schema: mod.parameters()
    }
  end
end
