defmodule KbaseBot.BuildInfo do
  @moduledoc """
  Build metadata captured at compile time (releases carry no .git directory,
  so the sha must be baked in during `mix release`).
  """

  git_sha =
    try do
      case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _ -> "unknown"
      end
    catch
      _, _ -> "unknown"
    end

  @git_sha git_sha

  def git_sha, do: @git_sha
end
