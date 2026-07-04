defmodule KbaseBot.Scheduler.CronTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Scheduler.Cron

  # next_fire_at is compared as TEXT against a UTC now in SQLite — local-offset
  # strings made sub-3h crons refire on every poll.
  test "next_fire_at returns UTC Z strings for zoned schedules" do
    after_dt = DateTime.new!(~D[2026-07-06], ~T[08:00:00], "America/Sao_Paulo")

    assert {:ok, iso} = Cron.next_fire_at("0 9 * * *", "America/Sao_Paulo", after_dt)
    assert String.ends_with?(iso, "Z")
    # 09:00 São Paulo (UTC-3) == 12:00 UTC
    assert iso == "2026-07-06T12:00:00Z"
  end

  test "next occurrence already past in local time rolls to the next day, still UTC" do
    after_dt = DateTime.new!(~D[2026-07-06], ~T[10:00:00], "America/Sao_Paulo")

    assert {:ok, iso} = Cron.next_fire_at("0 9 * * *", "America/Sao_Paulo", after_dt)
    assert iso == "2026-07-07T12:00:00Z"
  end

  test "invalid cron expression returns an error" do
    assert {:error, _} = Cron.next_fire_at("not a cron", "America/Sao_Paulo")
  end
end
