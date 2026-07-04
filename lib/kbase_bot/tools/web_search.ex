defmodule KbaseBot.Tools.WebSearch do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "web_search"

  @impl true
  def description do
    "Search the web for current information. Use when the user asks about something that requires up-to-date knowledge beyond the personal knowledge base."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Natural language search query"},
        category: %{
          type: "string",
          description:
            "Optional filter: company, people, research paper, news, personal site, financial report",
          enum: [
            "company",
            "people",
            "research paper",
            "news",
            "personal site",
            "financial report"
          ]
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def layer, do: :both

  @impl true
  def execute(%{"query" => query} = input, _context) do
    opts = %{}
    opts = if input["category"], do: Map.put(opts, "category", input["category"]), else: opts

    case KbaseBot.Exa.Client.search(query, opts) do
      {:ok, %{"results" => results}} ->
        formatted =
          results
          |> Enum.map(fn r ->
            parts = ["## #{r["title"]}", "URL: #{r["url"]}"]
            parts = if r["summary"], do: parts ++ [r["summary"]], else: parts

            parts =
              if r["highlights"] && r["highlights"] != [] do
                parts ++ ["Highlights:\n" <> Enum.join(r["highlights"], "\n---\n")]
              else
                parts
              end

            Enum.join(parts, "\n")
          end)
          |> Enum.join("\n\n")

        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
