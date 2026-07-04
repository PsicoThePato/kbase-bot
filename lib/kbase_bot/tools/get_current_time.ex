defmodule KbaseBot.Tools.GetCurrentTime do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "get_current_time"

  @impl true
  def description, do: "Returns the current date, time, and day of week in BRT (Brazil)."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :both

  @impl true
  def execute(_input, _context) do
    now = DateTime.now!("America/Sao_Paulo")
    day_of_week = day_name(Date.day_of_week(DateTime.to_date(now)))
    formatted = Calendar.strftime(now, "%Y-%m-%d %H:%M BRT")
    {:ok, "#{formatted} (#{day_of_week})"}
  end

  defp day_name(1), do: "Segunda-feira"
  defp day_name(2), do: "Terca-feira"
  defp day_name(3), do: "Quarta-feira"
  defp day_name(4), do: "Quinta-feira"
  defp day_name(5), do: "Sexta-feira"
  defp day_name(6), do: "Sabado"
  defp day_name(7), do: "Domingo"
end
