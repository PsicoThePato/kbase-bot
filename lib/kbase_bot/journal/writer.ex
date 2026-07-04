defmodule KbaseBot.Journal.Writer do
  @moduledoc """
  Appends entries to a daily journal file.
  One file per day: Journal/YYYY-MM-DD.md
  """

  require Logger

  def append_entry(text) do
    repo_path = KbaseBot.Context.Server.repo_path()
    now = DateTime.now!("America/Sao_Paulo")
    date_str = Calendar.strftime(now, "%Y-%m-%d")
    time_str = Calendar.strftime(now, "%H:%M")
    filename = "#{date_str}.md"
    file_path = Path.join([repo_path, "Journal", filename])

    content =
      if File.exists?(file_path) do
        "\n### #{time_str} BRT\n#{text}\n"
      else
        """
        ---
        date: #{date_str}
        ---

        ### #{time_str} BRT
        #{text}
        """
      end

    # Return {:error, posix} instead of raising so the journal_entry tool can
    # report the failure to the LLM rather than crashing the tool call
    with :ok <- File.mkdir_p(Path.dirname(file_path)),
         :ok <- File.write(file_path, content, [:append]) do
      # Log to SQLite
      KbaseBot.Repo.Store.execute(
        "INSERT INTO journal_entries (filename, message_text) VALUES (?1, ?2)",
        [filename, text]
      )

      # Git auto-commit
      if Application.get_env(:kbase_bot, :auto_commit, false) do
        auto_commit(repo_path, filename, text)
      end

      {:ok, filename, time_str}
    end
  end

  defp auto_commit(repo_path, _filename, text) do
    summary = String.slice(text, 0, 50)

    System.cmd("git", ["add", "Journal/"],
      cd: repo_path,
      stderr_to_stdout: true
    )

    System.cmd("git", ["commit", "-m", "journal: #{summary}"],
      cd: repo_path,
      stderr_to_stdout: true
    )
  end
end
