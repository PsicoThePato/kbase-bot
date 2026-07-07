defmodule KbaseBot.Federation.CirclesTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.{Circles, Contacts, Grants}
  alias KbaseBot.Principal
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(KbaseBot.Repo.Store)
    start_supervised!(KbaseBot.Context.Server)

    alice = FederationFixtures.peer("Alice")
    bob = FederationFixtures.peer("Bob")
    {:ok, _} = Contacts.add_card(alice.card)
    {:ok, _} = Contacts.add_card(bob.card)

    {:ok, Map.merge(ctx, %{alice: alice, bob: bob, owner: %{principal: Principal.owner()}})}
  end

  test "membership requires a known contact", %{alice: alice} do
    assert :ok = Circles.add("friends", alice.id)
    assert {:error, :unknown_contact} = Circles.add("friends", "sha256:stranger")
    assert Circles.members("friends") == [alice.id]
  end

  test "circle names are constrained slugs", %{alice: alice} do
    assert {:error, _} = Circles.add("Friends & family", alice.id)
  end

  test "grant_scope to circle:<name> creates one grant per member", ctx do
    :ok = Circles.add("friends", ctx.alice.id)
    :ok = Circles.add("friends", ctx.bob.id)

    assert {:ok, message} =
             KbaseBot.Tools.GrantScope.execute(
               %{"principal_id" => "circle:friends", "scope" => "movies"},
               ctx.owner
             )

    assert message =~ "2/2"
    assert Grants.covers?(ctx.alice.id, "movies", ["query"])
    assert Grants.covers?(ctx.bob.id, "movies", ["query"])
  end

  test "revoke_grant by circle + scope severs every member", ctx do
    :ok = Circles.add("friends", ctx.alice.id)
    :ok = Circles.add("friends", ctx.bob.id)
    {:ok, _} = Grants.create(ctx.alice.id, "movies", ["query"])
    {:ok, _} = Grants.create(ctx.bob.id, "movies", ["query"])

    assert {:ok, message} =
             KbaseBot.Tools.RevokeGrant.execute(
               %{"principal_id" => "circle:friends", "scope" => "movies"},
               ctx.owner
             )

    assert message =~ "Revoked 2"
    refute Grants.covers?(ctx.alice.id, "movies", ["query"])
    refute Grants.covers?(ctx.bob.id, "movies", ["query"])
  end

  test "granting to an empty circle fails loudly", ctx do
    assert {:error, message} =
             KbaseBot.Tools.GrantScope.execute(
               %{"principal_id" => "circle:ghosts", "scope" => "movies"},
               ctx.owner
             )

    assert message =~ "empty or unknown"
  end
end
