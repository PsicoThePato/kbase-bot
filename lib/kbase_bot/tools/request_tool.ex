defmodule KbaseBot.Tools.RequestTool do
  @behaviour KbaseBot.Tool

  @requests_file "priv/tool_requests.json"

  @impl true
  def name, do: "request_tool"

  @impl true
  def description do
    "Request a tool that you wish you had available. Describe what the tool should do and why you need it. The request will be saved for the developer to review."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        tool_name: %{
          type: "string",
          description: "A short snake_case name for the proposed tool"
        },
        description: %{
          type: "string",
          description: "What the tool should do and why it would be useful"
        },
        trigger: %{
          type: "string",
          description: "What situation triggered this request"
        }
      },
      required: ["tool_name", "description", "trigger"]
    }
  end

  @impl true
  def layer, do: :both

  @impl true
  def execute(%{"tool_name" => tool_name, "description" => desc, "trigger" => trigger}, _context) do
    entry = %{
      tool_name: tool_name,
      description: desc,
      trigger: trigger,
      requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    existing = read_requests()
    updated = existing ++ [entry]
    write_requests(updated)

    {:ok, "Tool request saved: #{tool_name}"}
  end

  def list_requests do
    read_requests()
  end

  defp read_requests do
    case File.read(@requests_file) do
      {:ok, content} -> Jason.decode!(content, keys: :atoms)
      {:error, :enoent} -> []
    end
  end

  defp write_requests(requests) do
    File.write!(@requests_file, Jason.encode!(requests, pretty: true))
  end
end
