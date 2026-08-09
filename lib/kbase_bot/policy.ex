defmodule KbaseBot.Policy do
  @moduledoc """
  Structural access control: which principal may do what to which resource.

  Enforcement lives in the tools — content is filtered before any LLM sees it,
  never in prompts (a peer's text is untrusted input). The owner may do
  everything; everyone else falls through to grants-based checks, which land
  with federation identity. Deny by default.
  """

  alias KbaseBot.Principal

  @doc """
  May `principal` read this knowledge-base file? An ungranted file must be
  indistinguishable from a missing one to the caller (deny by default).
  """
  @spec can_read_file?(Principal.t() | nil, String.t(), binary()) :: boolean()
  def can_read_file?(principal, rel_path, content) do
    Principal.owner?(principal) or granted_read?(principal, rel_path, content)
  end

  # Intersection semantics: every scope the file carries must be covered by a
  # live grant giving query or read. `private` can never be granted, so it
  # short-circuits. Any failure (including the store being down) fails closed.
  #
  # `query` deliberately authorizes file reads here: a query-grant responder
  # may quote file contents verbatim in its ANSWER (owner decision, 2026-07).
  # `read` remains the explicit raw-access capability for future direct reads.
  defp granted_read?(%Principal{id: id}, rel_path, content) do
    scopes = KbaseBot.Policy.Scopes.for_file(rel_path, content)

    scopes != [] and "private" not in scopes and
      Enum.all?(scopes, fn scope ->
        KbaseBot.Federation.Grants.covers?(id, scope, ["query", "read"])
      end)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp granted_read?(_, _, _), do: false
end
