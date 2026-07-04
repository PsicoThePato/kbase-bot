defmodule KbaseBot.Context.Server do
  @moduledoc """
  Holds user profile and repo path config in memory.
  Full knowledge base search is handled by QMD.
  """
  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def get_user_profile do
    GenServer.call(__MODULE__, :get_user_profile)
  end

  def repo_path do
    GenServer.call(__MODULE__, :repo_path)
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  # --- Server ---

  @impl true
  def init(_) do
    repo_path = Application.get_env(:kbase_bot, :repo_path, "./knowledge_base")
    user_profile = load_user_profile(repo_path)
    Logger.info("Context.Server started, repo_path=#{repo_path}")
    {:ok, %{repo_path: repo_path, user_profile: user_profile}}
  end

  @impl true
  def handle_call(:get_user_profile, _from, state) do
    {:reply, state.user_profile, state}
  end

  @impl true
  def handle_call(:repo_path, _from, state) do
    {:reply, state.repo_path, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    user_profile = load_user_profile(state.repo_path)
    Logger.info("Context.Server refreshed user profile")
    {:reply, :ok, %{state | user_profile: user_profile}}
  end

  defp load_user_profile(repo_path) do
    path = Path.join(repo_path, "user_profile.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> "(user profile not found)"
    end
  end
end
