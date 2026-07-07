defmodule KbaseBot.Federation.GrantPreview do
  @moduledoc """
  Dry-run of a prospective grant: which knowledge-base files would a
  principal be able to read if `(scope, query)` were granted, on top of what
  they can already read? Same rules as `Policy.can_read_file?` — scope
  resolution via frontmatter/policy defaults, intersection semantics, private
  short-circuit — evaluated hypothetically, so the owner sees the blast
  radius BEFORE signing the record.
  """

  alias KbaseBot.Federation.Grants
  alias KbaseBot.Policy.Scopes

  @doc """
  Preview granting `scope` to `principal_id`. Returns

      %{scope: ..., total: n, already_readable: n,
        newly_exposed: [path], still_blocked: [{path, missing_scopes}]}

  `still_blocked` lists files that carry `scope` but stay hidden because
  they also carry other, ungranted scopes (intersection semantics).
  """
  @spec preview(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def preview(principal_id, scope) do
    if scope in Scopes.non_grantable() do
      {:error, "scope #{scope} is non-grantable"}
    else
      policy = Scopes.load()
      files = kb_files()

      granted_now = fn s -> Grants.covers?(principal_id, s, ["query", "read"]) end

      {already, newly, blocked} =
        Enum.reduce(files, {[], [], []}, fn {rel_path, content}, {already, newly, blocked} ->
          scopes = Scopes.for_file(rel_path, content, policy)

          cond do
            "private" in scopes ->
              {already, newly, blocked}

            Enum.all?(scopes, granted_now) ->
              {[rel_path | already], newly, blocked}

            Enum.all?(scopes, fn s -> s == scope or granted_now.(s) end) ->
              {already, [rel_path | newly], blocked}

            scope in scopes ->
              missing = Enum.reject(scopes, fn s -> s == scope or granted_now.(s) end)
              {already, newly, [{rel_path, missing} | blocked]}

            true ->
              {already, newly, blocked}
          end
        end)

      {:ok,
       %{
         scope: scope,
         total: length(files),
         already_readable: length(already),
         newly_exposed: Enum.sort(newly),
         still_blocked: Enum.sort(blocked)
       }}
    end
  end

  defp kb_files do
    root = KbaseBot.Context.Server.repo_path()

    root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/.git/"))
    |> Enum.flat_map(fn full ->
      case File.read(full) do
        {:ok, content} -> [{Path.relative_to(full, root), content}]
        _ -> []
      end
    end)
  end
end
