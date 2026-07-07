defmodule KbaseBot.Federation.Publisher do
  @moduledoc """
  Publisher side of subscriptions. Cadence is owner-driven (the protocol
  doesn't dictate when to push). Before EVERY delivery the live grant is
  re-verified — revoking a grant kills the feed — and the file's full scope
  set must be covered for that recipient (intersection semantics hold for
  pushes too).
  """

  alias KbaseBot.Federation.{Envelope, Grants, Outbound, Subscriptions}
  alias KbaseBot.Identity.Keys
  alias KbaseBot.Policy.Scopes

  require Logger

  @doc "Publish a KB file to every live subscriber of `scope`. Returns a summary."
  @spec publish(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def publish(scope, rel_path) do
    repo_path = KbaseBot.Context.Server.repo_path()
    full_path = Path.join(repo_path, rel_path)

    with true <- String.starts_with?(Path.expand(full_path), Path.expand(repo_path)),
         {:ok, content} <- File.read(full_path) do
      file_scopes = Scopes.for_file(rel_path, content)

      if scope in file_scopes do
        {:ok, own_id} = Keys.own_principal_id()
        item = %{"path" => rel_path, "title" => rel_path, "content" => content}

        results =
          scope
          |> Subscriptions.active_subscribers()
          |> Enum.map(&deliver_to(&1, scope, file_scopes, item, own_id))

        delivered = Enum.count(results, &(&1 == :delivered))
        revoked = Enum.count(results, &(&1 == :revoked))
        skipped = Enum.count(results, &(&1 == :skipped))

        {:ok,
         "Published #{rel_path} to scope #{scope}: #{delivered} delivered" <>
           if(revoked > 0, do: ", #{revoked} feeds ended (grant revoked)", else: "") <>
           if(skipped > 0, do: ", #{skipped} skipped (file scopes not fully granted)", else: "")}
      else
        {:error,
         "#{rel_path} does not carry scope #{scope} (its scopes: #{Enum.join(file_scopes, ", ")})"}
      end
    else
      false -> {:error, "path traversal not allowed"}
      {:error, :enoent} -> {:error, "file not found: #{rel_path}"}
      {:error, reason} -> {:error, "cannot read #{rel_path}: #{inspect(reason)}"}
    end
  end

  defp deliver_to(subscription, scope, file_scopes, item, own_id) do
    peer = subscription.principal_id

    cond do
      # The subscription itself must still be backed by a live grant.
      not Grants.covers?(peer, scope, ["subscribe"]) ->
        Subscriptions.set_state("in", peer, scope, "revoked")
        :revoked

      # Intersection: every scope the file carries must be granted to the peer.
      not Enum.all?(file_scopes, &Grants.covers?(peer, &1, ["subscribe", "query", "read"])) ->
        :skipped

      true ->
        case Envelope.build("PUBLISH", %{
               "to" => peer,
               "scope" => scope,
               "item" => item,
               "provenance" => [own_id]
             }) do
          {:ok, envelope} ->
            case Outbound.deliver(envelope, peer) do
              :ok ->
                :delivered

              {:error, reason} ->
                Logger.warning("Publish to #{peer} failed: #{inspect(reason)}")
                :failed
            end

          _ ->
            :failed
        end
    end
  end
end
