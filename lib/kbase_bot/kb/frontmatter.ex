defmodule KbaseBot.KB.Frontmatter do
  @moduledoc """
  Minimal YAML frontmatter reader for knowledge-base markdown files.
  """

  @doc """
  Parse `---` fenced frontmatter at the start of `content`.
  Returns `{:ok, meta, body}` or `:none`.
  """
  @spec parse(binary()) :: {:ok, map(), binary()} | :none
  def parse("---\n" <> rest) do
    case String.split(rest, "\n---", parts: 2) do
      [yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, meta} when is_map(meta) -> {:ok, meta, String.trim_leading(body, "\n")}
          _ -> :none
        end

      _ ->
        :none
    end
  end

  def parse(_), do: :none

  @doc "The `scopes:` list from frontmatter, or nil when absent/unlabeled."
  @spec scopes(binary()) :: [String.t()] | nil
  def scopes(content) do
    with {:ok, meta, _body} <- parse(content),
         scopes when is_list(scopes) <- Map.get(meta, "scopes") do
      Enum.map(scopes, &to_string/1)
    else
      _ -> nil
    end
  end
end
