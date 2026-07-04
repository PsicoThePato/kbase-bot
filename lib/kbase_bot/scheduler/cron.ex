defmodule KbaseBot.Scheduler.Cron do
  @moduledoc """
  Cron expression utilities: parse and compute next fire time.
  Wraps the `crontab` hex package.
  """

  def next_fire_at(cron_expression, timezone \\ "America/Sao_Paulo", after_dt \\ nil) do
    case Crontab.CronExpression.Parser.parse(cron_expression) do
      {:ok, cron} ->
        base = after_dt || DateTime.now!(timezone)
        now = base |> DateTime.to_naive()

        case Crontab.Scheduler.get_next_run_date(cron, now) do
          {:ok, naive_dt} ->
            dt =
              naive_dt
              |> DateTime.from_naive!(timezone)
              |> DateTime.to_iso8601()

            {:ok, dt}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Invalid cron expression: #{inspect(reason)}"}
    end
  end
end
