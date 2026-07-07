defmodule KbaseBot.Tools.PreviewGrant do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Circles, GrantPreview}

  @max_listed 30

  @impl true
  def name, do: "preview_grant"

  @impl true
  def description do
    "Dry-run a prospective grant BEFORE creating it: shows exactly which knowledge-base files a principal (or every member of circle:<name>, or 'anyone') would newly be able to read if the scope were granted, plus files that stay blocked because they carry additional ungranted scopes. Nothing is granted."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{
          type: "string",
          description: "Contact principal id, 'anyone', or circle:<name>"
        },
        scope: %{type: "string", description: "The scope to preview, e.g. movies"}
      },
      required: ["principal_id", "scope"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => principal, "scope" => scope}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      if Circles.ref?(principal) do
        preview_circle(Circles.ref_name(principal), scope)
      else
        case GrantPreview.preview(principal, scope) do
          {:ok, result} -> {:ok, render(principal, result)}
          {:error, reason} -> {:error, to_string(reason)}
        end
      end
    end
  end

  defp preview_circle(name, scope) do
    case Circles.members(name) do
      [] ->
        {:error, "circle #{name} is empty or unknown (see list_circles)"}

      members ->
        sections =
          Enum.map(members, fn member ->
            case GrantPreview.preview(member, scope) do
              {:ok, result} -> render(member, result)
              {:error, reason} -> "#{member}: #{reason}"
            end
          end)

        {:ok, Enum.join(sections, "\n\n")}
    end
  end

  defp render(principal, result) do
    newly = result.newly_exposed

    header =
      "Granting #{result.scope} to #{principal} would newly expose " <>
        "#{length(newly)} file(s) (already readable: #{result.already_readable} " <>
        "of #{result.total} KB files):"

    listed =
      newly
      |> Enum.take(@max_listed)
      |> Enum.map_join("\n", &"- #{&1}")

    overflow =
      if length(newly) > @max_listed,
        do: "\n… and #{length(newly) - @max_listed} more",
        else: ""

    blocked =
      case result.still_blocked do
        [] ->
          ""

        blocked ->
          lines =
            blocked
            |> Enum.take(@max_listed)
            |> Enum.map_join("\n", fn {path, missing} ->
              "- #{path} (also carries: #{Enum.join(missing, ", ")})"
            end)

          "\n\nStill blocked despite this grant (intersection semantics):\n" <> lines
      end

    Enum.join([header, listed], "\n") <> overflow <> blocked
  end
end
