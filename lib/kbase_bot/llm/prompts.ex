defmodule KbaseBot.LLM.Prompts do
  @moduledoc """
  Prompt templates: compile-time defaults from priv/prompts/, with optional
  per-deployment overrides loaded at runtime.

  Overrides let a deployment customize prompts without forking the code: a
  file named like the default (e.g. `briefing.md`) placed in the override
  directory wins over the bundled default. The override directory is
  `:prompts_dir` config if set, otherwise `<repo_path>/prompts/` — inside the
  knowledge base, so personal prompts are encrypted at rest with the rest of
  the vault.
  """

  @manager_prompt_path "priv/prompts/manager.md"
  @personality_prompt_path "priv/prompts/personality.md"
  @task_execution_prompt_path "priv/prompts/task_execution.md"
  @briefing_prompt_path "priv/prompts/briefing.md"
  @federation_responder_prompt_path "priv/prompts/federation_responder.md"

  if File.exists?(@manager_prompt_path) do
    @external_resource @manager_prompt_path
    @manager_prompt File.read!(@manager_prompt_path)
  else
    @manager_prompt ""
  end

  if File.exists?(@personality_prompt_path) do
    @external_resource @personality_prompt_path
    @personality_prompt File.read!(@personality_prompt_path)
  else
    @personality_prompt ""
  end

  if File.exists?(@task_execution_prompt_path) do
    @external_resource @task_execution_prompt_path
    @task_execution_prompt File.read!(@task_execution_prompt_path)
  else
    @task_execution_prompt ""
  end

  if File.exists?(@briefing_prompt_path) do
    @external_resource @briefing_prompt_path
    @briefing_prompt File.read!(@briefing_prompt_path)
  else
    @briefing_prompt ""
  end

  if File.exists?(@federation_responder_prompt_path) do
    @external_resource @federation_responder_prompt_path
    @federation_responder_prompt File.read!(@federation_responder_prompt_path)
  else
    @federation_responder_prompt ""
  end

  def manager do
    base =
      prompt("manager.md", @manager_prompt) <>
        "\n\n" <> prompt("personality.md", @personality_prompt)

    case File.read(claude_md_path()) do
      {:ok, content} -> base <> "\n\n## Project Context\n\n" <> content
      {:error, _} -> base
    end
  end

  def task_execution(user_profile) do
    String.replace(
      prompt("task_execution.md", @task_execution_prompt),
      "{{user_profile}}",
      user_profile
    )
  end

  def briefing(day_of_week, date, user_profile) do
    prompt("briefing.md", @briefing_prompt)
    |> String.replace("{{day_of_week}}", day_of_week)
    |> String.replace("{{date}}", date)
    |> String.replace("{{user_profile}}", user_profile)
  end

  def federation_responder(scope, peer_name) do
    prompt("federation_responder.md", @federation_responder_prompt)
    |> String.replace("{{scope}}", scope || "unknown")
    |> String.replace("{{peer}}", peer_name || "unknown peer")
  end

  defp prompt(name, default) do
    case File.read(Path.join(prompts_dir(), name)) do
      {:ok, content} -> content
      {:error, _} -> default
    end
  end

  defp prompts_dir do
    Application.get_env(:kbase_bot, :prompts_dir) || Path.join(repo_path(), "prompts")
  end

  defp repo_path do
    Application.get_env(:kbase_bot, :repo_path, "./knowledge_base")
  end

  defp claude_md_path do
    Path.join(Path.dirname(repo_path()), "CLAUDE.md")
  end
end
