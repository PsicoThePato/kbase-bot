defmodule KbaseBot.Federation.IntegrationTest do
  @moduledoc """
  End-to-end federation pipeline in one VM via the loopback transport:
  peer QUERY → Inbox (sig verify → authorize → responder with stubbed LLM)
  → ANSWER envelope back out, plus the denial paths.
  """

  use ExUnit.Case, async: false

  alias KbaseBot.Federation.{Canonical, Contacts, Envelope, Exchanges, Grants, Inbox}
  alias KbaseBot.Identity.Keys

  setup do
    tmp = Path.join(System.tmp_dir!(), "kbase_fed_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "kb/movies"))

    # Knowledge base fixture: a movies-scoped file, a private file, a policy.
    File.write!(Path.join(tmp, "kb/movies/list.md"), """
    ---
    scopes: [movies]
    ---
    # Movies
    Dune Part Two: 9/10
    """)

    File.write!(Path.join(tmp, "kb/secret.md"), "# Unlabeled — must stay private\n")
    File.write!(Path.join(tmp, "kb/user_profile.md"), "test profile")

    File.write!(Path.join(tmp, "kb/.kbase-policy.yml"), """
    defaults:
      "**": {scopes: [private]}
    non_grantable: [medical]
    """)

    # Own federation identity.
    key_path = Path.join(tmp, "identity.json")
    {:ok, _own_id} = Keys.generate_to(key_path)

    old_env = %{
      db_path: Application.get_env(:kbase_bot, :db_path),
      repo_path: Application.get_env(:kbase_bot, :repo_path),
      federation_key_path: Application.get_env(:kbase_bot, :federation_key_path),
      llm_client: Application.get_env(:kbase_bot, :llm_client),
      loopback_receiver: Application.get_env(:kbase_bot, :loopback_receiver),
      qmd_enabled: Application.get_env(:kbase_bot, :qmd_enabled)
    }

    Application.put_env(:kbase_bot, :db_path, Path.join(tmp, "test.db"))
    Application.put_env(:kbase_bot, :repo_path, Path.join(tmp, "kb"))
    Application.put_env(:kbase_bot, :federation_key_path, key_path)
    Application.put_env(:kbase_bot, :llm_client, KbaseBot.Test.FakeLLM)
    Application.put_env(:kbase_bot, :loopback_receiver, self())
    Application.put_env(:kbase_bot, :qmd_enabled, false)

    # Keys are cached in persistent_term — reset between tests.
    :persistent_term.erase({KbaseBot.Identity.Keys, :keypair})

    start_supervised!(KbaseBot.Repo.Store)
    start_supervised!(KbaseBot.Context.Server)
    start_supervised!({Task.Supervisor, name: KbaseBot.TaskSupervisor})
    start_supervised!(KbaseBot.Federation.Inbox)

    # A peer with their own keypair and a loopback-only card.
    {peer_pub, peer_priv} = :crypto.generate_key(:eddsa, :ed25519)
    peer_id = Keys.fingerprint(peer_pub)

    peer_card =
      Canonical.sign(
        %{
          "v" => 1,
          "principal" => peer_id,
          "pubkey" => Base.encode64(peer_pub),
          "display_name" => "Alice",
          "seq" => 1,
          "identity_providers" => ["ed25519"],
          "endpoints" => [%{"transport" => "loopback", "address" => "local", "priority" => 1}],
          "scopes" => []
        },
        peer_priv
      )

    {:ok, ^peer_id} = Contacts.add_card(peer_card)

    on_exit(fn ->
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

    %{peer_id: peer_id, peer_priv: peer_priv, tmp: tmp}
  end

  defp peer_envelope(kind, fields, %{peer_id: peer_id, peer_priv: peer_priv}) do
    fields
    |> Map.merge(%{
      "v" => 1,
      "kind" => kind,
      "id" => Map.get(fields, "id", Envelope.new_id()),
      "from" => peer_id
    })
    |> Canonical.sign(peer_priv)
  end

  test "granted QUERY is answered end-to-end", ctx do
    {:ok, _} = Grants.create(ctx.peer_id, "movies", ["query"])

    query =
      peer_envelope("QUERY", %{"scope" => "movies", "question" => "any good movies?"}, ctx)

    Inbox.process(query)

    assert_receive {:federation_envelope, answer}, 3_000
    assert answer["kind"] == "ANSWER"
    assert answer["in_reply_to"] == query["id"]
    assert answer["answer"] =~ "FAKE-ANSWER"

    assert {:ok, %{state: "answered"}} = Exchanges.find("in", query["id"])
  end

  test "ungranted QUERY gets an indistinguishable DECLINE", ctx do
    query = peer_envelope("QUERY", %{"scope" => "movies", "question" => "hello?"}, ctx)
    Inbox.process(query)

    assert_receive {:federation_envelope, decline}, 3_000
    assert decline["kind"] == "DECLINE"
    assert decline["reason"] == "no_answer"
  end

  test "QUERY with a proof chain is declined (transitive out of v1)", ctx do
    {:ok, _} = Grants.create(ctx.peer_id, "movies", ["query"])

    query =
      peer_envelope(
        "QUERY",
        %{"scope" => "movies", "question" => "q", "proof" => [%{"fake" => "record"}]},
        ctx
      )

    Inbox.process(query)

    assert_receive {:federation_envelope, decline}, 3_000
    assert decline["kind"] == "DECLINE"
  end

  test "tampered signature is dropped silently", ctx do
    query =
      peer_envelope("QUERY", %{"scope" => "movies", "question" => "q"}, ctx)
      |> Map.put("question", "tampered")

    assert Inbox.process(query) == :drop
    refute_receive {:federation_envelope, _}, 300
  end

  test "unknown sender is dropped", ctx do
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    query =
      %{
        "v" => 1,
        "kind" => "QUERY",
        "id" => "x",
        "from" => "sha256:stranger",
        "scope" => "movies"
      }
      |> Canonical.sign(priv)

    assert Inbox.process(query) == :drop
    refute_receive {:federation_envelope, _}, 300
    _ = ctx
  end

  test "LIST-SCOPES returns exactly the granted + anyone scopes", ctx do
    {:ok, _} = Grants.create(ctx.peer_id, "movies", ["query"])
    {:ok, _} = Grants.create("anyone", "ttrpg", ["query"])
    {:ok, _} = Grants.create("sha256:someone_else", "books", ["query"])

    req = peer_envelope("LIST-SCOPES", %{}, ctx)
    Inbox.process(req)

    assert_receive {:federation_envelope, scopes_env}, 3_000
    assert scopes_env["kind"] == "SCOPES"
    names = Enum.map(scopes_env["scopes"], & &1["name"])
    assert Enum.sort(names) == ["movies", "ttrpg"]
  end

  test "unsolicited ANSWER is dropped", ctx do
    answer =
      peer_envelope("ANSWER", %{"in_reply_to" => "never-sent", "answer" => "gotcha"}, ctx)

    assert Inbox.process(answer) == :drop
  end

  test "unknown envelope kind is declined, not crashed", ctx do
    weird = peer_envelope("GOSSIP-9000", %{"stuff" => "x"}, ctx)
    Inbox.process(weird)

    assert_receive {:federation_envelope, decline}, 3_000
    assert decline["kind"] == "DECLINE"
  end

  test "non-grantable scope cannot be granted, even to anyone", ctx do
    assert {:error, msg} = Grants.create(ctx.peer_id, "medical", ["query"])
    assert msg =~ "non-grantable"
    assert {:error, _} = Grants.create("anyone", "private", ["query"])
  end

  test "revocation kills authorization immediately", ctx do
    {:ok, grant_id} = Grants.create(ctx.peer_id, "movies", ["query"])

    assert {:ok, _} =
             KbaseBot.Federation.Verifier.authorize(ctx.peer_id, "movies", "query")

    :ok = Grants.revoke(grant_id)

    assert {:error, :declined} =
             KbaseBot.Federation.Verifier.authorize(ctx.peer_id, "movies", "query")
  end

  test "policy: peer reads granted file, private file stays invisible", ctx do
    {:ok, _} = Grants.create(ctx.peer_id, "movies", ["query"])
    peer = %KbaseBot.Principal{id: ctx.peer_id, provider: :ed25519}

    assert {:ok, content} =
             KbaseBot.Tools.ReadFile.execute(%{"path" => "movies/list.md"}, %{principal: peer})

    assert content =~ "Dune"

    # Unlabeled file falls to private — indistinguishable from missing.
    assert {:error, "File not found: secret.md"} =
             KbaseBot.Tools.ReadFile.execute(%{"path" => "secret.md"}, %{principal: peer})

    # list_files shows only the granted file.
    {:ok, tree} = KbaseBot.Tools.ListFiles.execute(%{}, %{principal: peer})
    assert tree =~ "movies/list.md"
    refute tree =~ "secret.md"
  end
end
