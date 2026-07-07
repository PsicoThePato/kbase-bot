defmodule KbaseBot.Federation.Binder do
  @moduledoc """
  The LLM-judgment step of the translation layer: when a peer's SCOPES answer
  arrives, match their scope names/descriptions against the owner's topic
  vocabulary. Auto-bind above the confidence threshold; escalate ambiguity to
  the owner; ignore clear non-matches.
  """

  alias KbaseBot.Federation.Bindings
  alias KbaseBot.Policy.Scopes

  require Logger

  @auto_threshold 80
  @ask_threshold 50

  @doc "Propose and apply bindings for a peer's advertised scopes."
  def propose(peer_id, peer_scopes) when is_list(peer_scopes) do
    topics = owner_topics()

    if topics == [] or peer_scopes == [] do
      :ok
    else
      case llm_proposals(topics, peer_scopes) do
        {:ok, proposals} ->
          {auto, ask} = classify(proposals, topics, Enum.map(peer_scopes, & &1["name"]))

          Enum.each(auto, fn p ->
            Bindings.upsert(p["topic"], peer_id, p["peer_scope"], p["confidence"], false)
          end)

          Enum.each(ask, fn p ->
            # This binder is itself a confined, toolless classifier whose
            # output is validated against our own vocabulary; its proposals
            # reach the owner only, never the Manager loop. The owner confirms
            # by telling the assistant, quoting the scope name themselves.
            KbaseBot.Federation.OwnerNotifier.notify_owner(
              "[Federation] Possible binding at #{peer_id}: their scope " <>
                "\"#{p["peer_scope"]}\" ≈ your topic \"#{p["topic"]}\" " <>
                "(confidence #{p["confidence"]}%). To accept, tell your assistant to " <>
                "bind it (it will use bind_topic); otherwise ignore."
            )
          end)

          :ok

        {:error, reason} ->
          Logger.warning("Federation binder: proposal failed: #{inspect(reason)}")
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("Federation binder crashed: #{inspect(e)}")
      :ok
  end

  @doc """
  Pure classifier: keep only proposals naming known topics/scopes, split into
  {auto_bind, ask_owner} by confidence thresholds (#{@auto_threshold}/#{@ask_threshold}).
  """
  def classify(proposals, known_topics, known_peer_scopes) do
    valid =
      Enum.filter(proposals, fn p ->
        is_map(p) and p["topic"] in known_topics and p["peer_scope"] in known_peer_scopes and
          is_integer(p["confidence"])
      end)

    {
      Enum.filter(valid, &(&1["confidence"] >= @auto_threshold)),
      Enum.filter(
        valid,
        &(&1["confidence"] >= @ask_threshold and &1["confidence"] < @auto_threshold)
      )
    }
  end

  @doc "The owner's topic vocabulary: scope labels from the policy file, minus private."
  def owner_topics(policy \\ nil) do
    policy = policy || Scopes.load()

    from_defaults =
      policy
      |> Map.get("defaults", %{})
      |> Map.values()
      |> Enum.flat_map(&(&1["scopes"] || []))

    from_descriptions = policy |> Map.get("scope_descriptions", %{}) |> Map.keys()

    (from_defaults ++ from_descriptions)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "private"))
    |> Enum.sort()
  end

  defp llm_proposals(topics, peer_scopes) do
    scope_lines =
      Enum.map_join(peer_scopes, "\n", fn s ->
        case s["description"] do
          nil -> "- #{s["name"]}"
          desc -> "- #{s["name"]}: #{desc}"
        end
      end)

    prompt = """
    Match a peer's knowledge scopes to my topic vocabulary.

    My topics: #{Enum.join(topics, ", ")}

    Peer scopes:
    #{scope_lines}

    Return ONLY a JSON array (no prose) of plausible matches:
    [{"topic": "<one of my topics>", "peer_scope": "<one of their scopes>", "confidence": <0-100 integer>}]
    Only include pairs that plausibly refer to the same subject. Different
    languages for the same subject (e.g. "saude"/"health") are strong matches.
    """

    client = Application.get_env(:kbase_bot, :llm_client, KbaseBot.LLM.Client)

    with {:ok, response} <-
           client.chat(
             "You map vocabulary labels between agents. Output strict JSON.",
             [%{"role" => "user", "content" => prompt}],
             []
           ),
         text = KbaseBot.LLM.Client.extract_text(response),
         {:ok, proposals} when is_list(proposals) <- decode_json_array(text) do
      {:ok, proposals}
    else
      other -> {:error, other}
    end
  end

  # The model may wrap JSON in fences or prose — parse from the first "[".
  defp decode_json_array(text) do
    case :binary.match(text, "[") do
      {pos, _} ->
        Jason.decode(binary_part(text, pos, byte_size(text) - pos) |> trim_after_array())

      :nomatch ->
        {:error, :no_json}
    end
  end

  defp trim_after_array(text) do
    case :binary.matches(text, "]") do
      [] ->
        text

      matches ->
        {pos, _} = List.last(matches)
        binary_part(text, 0, pos + 1)
    end
  end
end
