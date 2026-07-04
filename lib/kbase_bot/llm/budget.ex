defmodule KbaseBot.LLM.Budget do
  @moduledoc """
  Hard daily cap on LLM API calls — a backstop against error loops
  (misfiring schedules, LLM-mediated retry cycles) burning tokens
  unattended. Counts calls rather than tokens: coarse, but a fuse only
  needs to blow, not to meter.

  Fail-open by design: if the store is unavailable the call proceeds.
  The budget protects the wallet; it must never be what breaks the bot.
  """

  require Logger

  alias KbaseBot.Repo.Store

  @default_budget 300

  @doc """
  Count one prospective LLM call against today's budget.

  Returns `:ok` when the call may proceed, `{:error, :llm_budget_exceeded}`
  once today's budget (config `:daily_llm_call_budget`) is exhausted.
  Sends a one-time Telegram alert the first time the cap is hit each day.
  """
  def check_and_increment do
    budget = Application.get_env(:kbase_bot, :daily_llm_call_budget) || @default_budget
    day = Date.utc_today() |> Date.to_iso8601()

    with :ok <-
           Store.execute(
             "INSERT INTO llm_daily_usage (day, calls) VALUES (?1, 1) " <>
               "ON CONFLICT(day) DO UPDATE SET calls = calls + 1",
             [day]
           ),
         {:ok, [[calls, alerted]]} <-
           Store.query("SELECT calls, alerted FROM llm_daily_usage WHERE day = ?1", [day]) do
      if calls <= budget do
        :ok
      else
        if alerted == 0, do: alert(day, budget)
        {:error, :llm_budget_exceeded}
      end
    else
      other ->
        Logger.warning("LLM budget check unavailable (#{inspect(other)}) — allowing call")
        :ok
    end
  rescue
    e ->
      Logger.warning("LLM budget check crashed (#{inspect(e)}) — allowing call")
      :ok
  catch
    kind, reason ->
      Logger.warning("LLM budget check #{kind} (#{inspect(reason)}) — allowing call")
      :ok
  end

  defp alert(day, budget) do
    Store.execute("UPDATE llm_daily_usage SET alerted = 1 WHERE day = ?1", [day])

    case Application.get_env(:kbase_bot, :telegram_chat_id) do
      nil ->
        :ok

      chat_id ->
        KbaseBot.Telegram.send_message(
          chat_id,
          "⚠️ Daily LLM budget exhausted (#{budget} calls) — pausing LLM calls until " <>
            "tomorrow (UTC). If you weren't expecting this, a schedule or task may be " <>
            "looping; check `journalctl -u kbase-bot` and your schedules."
        )
    end
  end
end
