defmodule KbaseBot.Tools.LogPreference do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "log_preference"

  @impl true
  def description do
    "Record a user preference or a correction the user made to something you did. " <>
      "Call this whenever the user states a like/dislike, overrides a suggestion, or " <>
      "corrects you — before responding. These records are training data: capture the " <>
      "generalization, not just the instance."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        statement: %{
          type: "string",
          description:
            "The preference or correction, stated plainly (e.g. 'meat weights in meal logs are always cooked weight')"
        },
        wrong: %{
          type: "string",
          description: "What you did or assumed that was wrong, if this is a correction"
        },
        lesson: %{
          type: "string",
          description: "The generalization: how to act differently in the future"
        }
      },
      required: ["statement"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context), do: do_execute(input)
  end

  defp do_execute(%{"statement" => statement} = input) do
    date = Date.utc_today() |> Date.to_iso8601()

    entry =
      ["\n### #{date}\n", "- **Preference:** #{statement}\n"] ++
        maybe("  - Was doing: ", input["wrong"]) ++
        maybe("  - Lesson: ", input["lesson"])

    case KbaseBot.KB.Writer.append("preferences/log.md", IO.iodata_to_binary(entry),
           actor: "jairo",
           source: "log_preference",
           meta: %{wrong: input["wrong"], lesson: input["lesson"]}
         ) do
      {:ok, _} -> {:ok, "Preference logged."}
      {:error, reason} -> {:error, "could not log preference: #{inspect(reason)}"}
    end
  end

  defp maybe(_label, nil), do: []
  defp maybe(label, text), do: [label, text, "\n"]
end
