defmodule KbaseBot.Policy.Scopes do
  @moduledoc """
  Resolve a knowledge-base file to its scope set.

  Precedence: frontmatter `scopes:` → `.kbase-policy.yml` path defaults
  (most-specific glob wins) → `["private"]`. Unlabeled content is always
  private. Access semantics are intersection (most restrictive wins): a
  principal reaches a file only with the capability on every scope it carries.
  """

  alias KbaseBot.KB.Frontmatter

  @policy_file ".kbase-policy.yml"
  @catch_all ["private"]

  @doc "Scope set for a file. `policy` is injectable for tests."
  @spec for_file(String.t(), binary(), map() | nil) :: [String.t()]
  def for_file(rel_path, content, policy \\ nil) do
    Frontmatter.scopes(content) || default_scopes(rel_path, policy || load()) || @catch_all
  end

  @doc "Path-default scopes from the policy map, most-specific glob wins."
  @spec default_scopes(String.t(), map()) :: [String.t()] | nil
  def default_scopes(rel_path, policy) do
    policy
    |> Map.get("defaults", %{})
    |> Enum.filter(fn {glob, _} -> glob_match?(glob, rel_path) end)
    |> Enum.max_by(fn {glob, _} -> specificity(glob) end, fn -> nil end)
    |> case do
      {_glob, %{"scopes" => scopes}} when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      _ -> nil
    end
  end

  @doc "Scopes no grant may ever name. `private` is always non-grantable."
  @spec non_grantable(map() | nil) :: [String.t()]
  def non_grantable(policy \\ nil) do
    policy = policy || load()
    Enum.uniq(@catch_all ++ Enum.map(Map.get(policy, "non_grantable", []), &to_string/1))
  end

  @doc "Load `.kbase-policy.yml` from the knowledge-base root (empty map if absent)."
  @spec load() :: map()
  def load do
    path = Path.join(KbaseBot.Context.Server.repo_path(), @policy_file)

    case YamlElixir.read_from_file(path) do
      {:ok, policy} when is_map(policy) -> policy
      _ -> %{}
    end
  end

  @doc "Glob match supporting `**` (any depth) and `*` (single path segment)."
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(glob, path) do
    {:ok, regex} = glob |> glob_to_regex() |> Regex.compile()
    Regex.match?(regex, path)
  end

  defp glob_to_regex(glob) do
    inner =
      glob
      |> String.split("**")
      |> Enum.map_join(".*", fn part ->
        part
        |> String.split("*")
        |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    "^" <> inner <> "$"
  end

  # Longest literal (non-wildcard) content wins; the bare "**" catch-all is 0.
  defp specificity(glob), do: glob |> String.replace("*", "") |> String.length()
end
