# Boot script for the demo's PEER instance ("Bob") — run by `mix kbase_bot.demo`
# in a separate OS process as `mix run --no-halt priv/demo/peer_boot.exs`, with
# KBASE_DEMO=true and its own DB/KB/identity/port via env.
#
# Protocol with the driver (over stdout lines):
#   PEER-PID <os pid>   — printed first, so the driver can kill/restart us
#   OWNER-MSG <text>    — anything our OwnerNotifier/notify_user would Telegram
#   PEER-READY          — setup done: driver's card added, demo grant created,
#                         our card written to BOB_CARD_FILE
#
# Idempotent on purpose: the store-and-forward act restarts this instance
# against the same DB, so a stale card or an existing grant is not an error.

alias KbaseBot.Federation.{Card, Contacts, Grants, Rotation}

Logger.configure(level: :warning)

IO.puts("PEER-PID #{System.pid()}")

# Owner-facing messages become prefixed stdout lines instead of Telegram.
sink =
  spawn(fn ->
    Stream.repeatedly(fn ->
      receive do
        {:telegram, _chat, text} -> IO.puts("OWNER-MSG " <> String.replace(text, "\n", " "))
        _ -> :ok
      end
    end)
    |> Stream.run()
  end)

Application.put_env(:kbase_bot, :message_sink, sink)

alice_card_file = System.fetch_env!("ALICE_CARD_FILE")
bob_card_file = System.fetch_env!("BOB_CARD_FILE")

wait_for_file = fn wait_for_file, path, tries ->
  cond do
    File.exists?(path) -> :ok
    tries <= 0 -> raise "timed out waiting for #{path}"
    true ->
      Process.sleep(200)
      wait_for_file.(wait_for_file, path, tries - 1)
  end
end

wait_for_file.(wait_for_file, alice_card_file, 100)

alice_card = alice_card_file |> File.read!() |> Jason.decode!()
alice_id = alice_card["principal"]

case Contacts.add_card(alice_card, "demo driver") do
  {:ok, _} -> :ok
  {:error, :stale_card} -> :ok
  {:error, reason} -> raise "could not add driver card: #{inspect(reason)}"
end

unless Grants.covers?(alice_id, "movies", ["query"]) do
  {:ok, _} = Grants.create(alice_id, "movies", ["query"])
end

endpoints = [
  %{
    "transport" => "https",
    "address" =>
      String.trim_trailing(System.fetch_env!("FEDERATION_PUBLIC_URL"), "/") <>
        "/federation/inbox",
    "priority" => 1
  }
]

{:ok, card} =
  Card.build(
    System.get_env("FEDERATION_DISPLAY_NAME", "Bob"),
    System.os_time(:second),
    endpoints,
    Grants.granted_scopes("anyone"),
    Rotation.proof()
  )

File.write!(bob_card_file, Jason.encode!(card))
IO.puts("PEER-READY")
