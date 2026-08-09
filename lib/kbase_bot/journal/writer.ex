defmodule KbaseBot.Journal.Writer do
  @moduledoc """
  Appends entries to a daily journal file, one file per day:
  Journal/YYYY-MM-DD.md. All writes go through KB.Writer, so the durable
  record is the kb_writes log; the markdown file is a materialized view.
  """

  alias KbaseBot.KB

  def append_entry(text) do
    now = DateTime.now!(timezone())
    date_str = Calendar.strftime(now, "%Y-%m-%d")
    time_str = Calendar.strftime(now, "%H:%M")
    filename = "#{date_str}.md"
    rel_path = Path.join("Journal", filename)
    full_path = Path.join(KbaseBot.Context.Server.repo_path(), rel_path)

    entry = "### #{time_str} #{now.zone_abbr}\n#{text}\n"
    opts = [actor: "jairo", source: "journal", meta: %{tz: timezone()}]

    result =
      if File.exists?(full_path) do
        KB.Writer.append(rel_path, "\n" <> entry, opts)
      else
        KB.Writer.write(rel_path, "---\ndate: #{date_str}\n---\n\n" <> entry, opts)
      end

    with {:ok, _} <- result do
      if Application.get_env(:kbase_bot, :auto_commit, false) do
        auto_commit(KbaseBot.Context.Server.repo_path(), text)
      end

      {:ok, filename, time_str}
    end
  end

  defp timezone, do: Application.get_env(:kbase_bot, :timezone, "America/Sao_Paulo")

  defp auto_commit(repo_path, text) do
    summary = String.slice(text, 0, 50)

    System.cmd("git", ["add", "Journal/"], cd: repo_path, stderr_to_stdout: true)

    System.cmd("git", ["commit", "-m", "journal: #{summary}"],
      cd: repo_path,
      stderr_to_stdout: true
    )
  end
end
