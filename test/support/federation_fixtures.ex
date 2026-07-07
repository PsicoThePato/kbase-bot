defmodule KbaseBot.Test.FederationFixtures do
  @moduledoc """
  Shared setup for federation tests: a tmp knowledge base + store + own
  identity, and peer fixtures with their own keypairs. Mirrors the
  integration test's environment handling (save/restore app env, reset the
  persistent_term key cache).
  """

  alias KbaseBot.Federation.Canonical
  alias KbaseBot.Identity.Keys

  @env_keys [
    :db_path,
    :repo_path,
    :federation_key_path,
    :llm_client,
    :loopback_receiver,
    :message_sink,
    :telegram_chat_id,
    :qmd_enabled,
    :federation_peer_monthly_loops,
    :federation_unreachable_alert_s
  ]

  @doc """
  Create a tmp dir with a kb/, an own identity, and app env pointing at
  them. Returns `%{tmp: tmp}`. Call from `setup`, passing the ExUnit
  context-less callback style: `setup do: FederationFixtures.bootstrap()`.
  """
  def bootstrap do
    tmp = Path.join(System.tmp_dir!(), "kbase_fed_fix_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "kb"))

    key_path = Path.join(tmp, "identity.json")
    {:ok, _own_id} = Keys.generate_to(key_path)

    old_env = Map.new(@env_keys, fn key -> {key, Application.get_env(:kbase_bot, key)} end)

    Application.put_env(:kbase_bot, :db_path, Path.join(tmp, "test.db"))
    Application.put_env(:kbase_bot, :repo_path, Path.join(tmp, "kb"))
    Application.put_env(:kbase_bot, :federation_key_path, key_path)
    Application.put_env(:kbase_bot, :llm_client, KbaseBot.Test.FakeLLM)
    Application.put_env(:kbase_bot, :loopback_receiver, self())
    Application.put_env(:kbase_bot, :message_sink, self())
    Application.put_env(:kbase_bot, :telegram_chat_id, 4_242)
    Application.put_env(:kbase_bot, :qmd_enabled, false)

    :persistent_term.erase({KbaseBot.Identity.Keys, :keypair})

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(old_env, fn {key, value} ->
        if value == nil do
          Application.delete_env(:kbase_bot, key)
        else
          Application.put_env(:kbase_bot, key, value)
        end
      end)

      :persistent_term.erase({KbaseBot.Identity.Keys, :keypair})
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  @doc "A peer with its own keypair and a card (endpoints default to loopback)."
  def peer(display_name, endpoints \\ nil) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    id = Keys.fingerprint(pub)

    endpoints =
      endpoints || [%{"transport" => "loopback", "address" => "local", "priority" => 1}]

    card =
      Canonical.sign(
        %{
          "v" => 1,
          "principal" => id,
          "pubkey" => Base.encode64(pub),
          "display_name" => display_name,
          "seq" => 1,
          "identity_providers" => ["ed25519"],
          "endpoints" => endpoints,
          "scopes" => []
        },
        priv
      )

    %{id: id, pub: pub, priv: priv, card: card}
  end

  @doc "A signed envelope from the given peer fixture."
  def envelope(peer, kind, fields) do
    fields
    |> Map.merge(%{
      "v" => 1,
      "kind" => kind,
      "id" => Map.get(fields, "id", KbaseBot.Federation.Envelope.new_id()),
      "ts" => Map.get(fields, "ts", System.os_time(:second)),
      "from" => peer.id
    })
    |> Canonical.sign(peer.priv)
  end
end
