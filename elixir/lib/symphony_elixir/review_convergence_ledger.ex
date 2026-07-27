defmodule SymphonyElixir.ReviewConvergenceLedger do
  @moduledoc """
  Versioned wire authority for durable review-rework and Convergence Hold events.

  The ledger accepts one exact JSON sentinel per comment, rejects duplicate object keys and
  unknown fields, and reconstructs history without interpreting surrounding prose.
  """

  @sentinel_prefix "<!-- symphony-review-convergence-ledger:"
  @sentinel_open "<!-- symphony-review-convergence-ledger:v1\n"
  @sentinel_close "\n-->"
  @cluster_id_pattern ~r/\Asymphony-review-finding-cluster:v1:[0-9a-f]{64}\z/
  @head_sha_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @dedup_id_pattern ~r/\A[0-9a-f]{64}\z/

  @transition_keys [
    "schema_version",
    "event",
    "operation_id",
    "round",
    "head_sha",
    "target_state",
    "cluster_ids"
  ]

  @hold_keys [
    "schema_version",
    "event",
    "hold_id",
    "head_sha",
    "reason",
    "cluster_ids"
  ]

  @reason_by_wire_value %{
    "repeated_cluster" => :repeated_cluster,
    "fix_round_budget_exhausted" => :fix_round_budget_exhausted,
    "unclusterable_evidence" => :unclusterable_evidence,
    "invalid_ledger" => :invalid_ledger,
    "legacy_rework_without_manifest" => :legacy_rework_without_manifest
  }

  @wire_reason_by_atom Map.new(@reason_by_wire_value, fn {wire, atom} -> {atom, wire} end)

  @type transition_event :: %{
          required(:kind) => :rework_intent | :rework_completed,
          required(:operation_id) => String.t(),
          required(:round) => pos_integer(),
          required(:head_sha) => String.t(),
          required(:target_state) => String.t(),
          required(:cluster_ids) => [String.t()]
        }

  @type hold_reason ::
          :repeated_cluster
          | :fix_round_budget_exhausted
          | :unclusterable_evidence
          | :invalid_ledger
          | :legacy_rework_without_manifest

  @type hold_event :: %{
          required(:kind) => :convergence_hold,
          required(:hold_id) => String.t(),
          required(:head_sha) => String.t(),
          required(:reason) => hold_reason(),
          required(:cluster_ids) => [String.t()]
        }

  @type event :: transition_event() | hold_event()

  @type history :: %{
          required(:rework_count) => non_neg_integer(),
          required(:pending_transitions) => %{optional(String.t()) => transition_event()},
          required(:last_completed_rework) => transition_event() | nil,
          required(:completed_cluster_ids_by_head) => %{optional(String.t()) => MapSet.t(String.t())},
          required(:holds_by_head) => %{optional(String.t()) => hold_event()}
        }

  @type parse_error ::
          :duplicate_ledger_event
          | :malformed_ledger_event
          | :unsupported_ledger_version
          | :unknown_ledger_event
          | :unknown_ledger_field
          | :invalid_ledger_event
          | :invalid_operation_id
          | :invalid_hold_id
          | :invalid_head_sha
          | :invalid_cluster_id
          | :noncanonical_cluster_ids

  @type history_error ::
          parse_error()
          | :contradictory_operation
          | :completion_without_intent
          | :completion_manifest_mismatch
          | :duplicate_rework_round
          | :noncontiguous_rework_rounds
          | :multiple_pending_reworks
          | :invalid_pending_rework_round
          | :contradictory_hold

  @spec encode(event()) :: {:ok, String.t()} | {:error, parse_error()}
  def encode(event) when is_map(event) do
    with {:ok, wire} <- event_to_wire(event) do
      {:ok, @sentinel_open <> Jason.encode!(wire) <> @sentinel_close}
    end
  end

  def encode(_event), do: {:error, :invalid_ledger_event}

  @spec parse_comment(String.t()) :: :none | {:ok, event()} | {:error, parse_error()}
  def parse_comment(body) when is_binary(body) do
    prefix_count = body |> :binary.matches(@sentinel_prefix) |> length()
    exact_count = body |> :binary.matches(@sentinel_open) |> length()

    cond do
      prefix_count == 0 ->
        :none

      prefix_count > 1 or exact_count > 1 ->
        {:error, :duplicate_ledger_event}

      exact_count == 0 ->
        {:error, :unsupported_ledger_version}

      true ->
        parse_exact_block(body)
    end
  end

  def parse_comment(_body), do: {:error, :malformed_ledger_event}

  @spec history([String.t()]) :: {:ok, history()} | {:error, history_error()}
  def history(comment_bodies) when is_list(comment_bodies) do
    initial = %{intents: %{}, completions: %{}, holds: %{}}

    with {:ok, collected} <- collect_events(comment_bodies, initial),
         :ok <- validate_operation_pairs(collected),
         :ok <- validate_rounds(collected) do
      finalize_history(collected)
    end
  end

  def history(_comment_bodies), do: {:error, :malformed_ledger_event}

  defp parse_exact_block(body) do
    [_before, rest] = String.split(body, @sentinel_open, parts: 2)

    case String.split(rest, @sentinel_close, parts: 2) do
      [json, _after] -> decode_event(json)
      _unterminated -> {:error, :malformed_ledger_event}
    end
  end

  defp decode_event(json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = decoded} ->
        with {:ok, payload} <- unique_json_value(decoded),
             {:ok, event} <- wire_to_event(payload) do
          {:ok, event}
        else
          :duplicate -> {:error, :malformed_ledger_event}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :malformed_ledger_event}
    end
  end

  defp unique_json_value(%Jason.OrderedObject{values: members}) do
    Enum.reduce_while(members, {:ok, {MapSet.new(), %{}}}, &unique_object_member/2)
    |> case do
      {:ok, {_keys, map}} -> {:ok, map}
      :duplicate -> :duplicate
    end
  end

  defp unique_json_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case unique_json_value(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        :duplicate -> {:halt, :duplicate}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :duplicate -> :duplicate
    end
  end

  defp unique_json_value(value), do: {:ok, value}

  defp unique_object_member({key, value}, {:ok, {keys, map}}) do
    if MapSet.member?(keys, key) do
      {:halt, :duplicate}
    else
      unique_object_value(key, value, keys, map)
    end
  end

  defp unique_object_value(key, value, keys, map) do
    case unique_json_value(value) do
      {:ok, normalized} ->
        {:cont, {:ok, {MapSet.put(keys, key), Map.put(map, key, normalized)}}}

      :duplicate ->
        {:halt, :duplicate}
    end
  end

  defp wire_to_event(%{"schema_version" => version}) when version != 1,
    do: {:error, :unsupported_ledger_version}

  defp wire_to_event(%{"schema_version" => 1, "event" => event} = payload)
       when event in ["rework_intent", "rework_completed"] do
    with :ok <- exact_keys(payload, @transition_keys),
         :ok <- valid_operation_id(payload["operation_id"]),
         :ok <- valid_round(payload["round"]),
         :ok <- valid_head_sha(payload["head_sha"]),
         :ok <- valid_nonblank(payload["target_state"]),
         {:ok, cluster_ids} <- parse_cluster_ids(payload["cluster_ids"], false) do
      {:ok,
       %{
         kind: if(event == "rework_intent", do: :rework_intent, else: :rework_completed),
         operation_id: payload["operation_id"],
         round: payload["round"],
         head_sha: payload["head_sha"],
         target_state: payload["target_state"],
         cluster_ids: cluster_ids
       }}
    end
  end

  defp wire_to_event(%{"schema_version" => 1, "event" => "convergence_hold"} = payload) do
    with :ok <- exact_keys(payload, @hold_keys),
         :ok <- valid_hold_id(payload["hold_id"]),
         :ok <- valid_head_sha(payload["head_sha"]),
         {:ok, reason} <- hold_reason(payload["reason"]),
         {:ok, cluster_ids} <- parse_cluster_ids(payload["cluster_ids"], true) do
      {:ok,
       %{
         kind: :convergence_hold,
         hold_id: payload["hold_id"],
         head_sha: payload["head_sha"],
         reason: reason,
         cluster_ids: cluster_ids
       }}
    end
  end

  defp wire_to_event(%{"schema_version" => 1, "event" => _unknown}),
    do: {:error, :unknown_ledger_event}

  defp wire_to_event(_payload), do: {:error, :malformed_ledger_event}

  defp event_to_wire(%{kind: kind} = event) when kind in [:rework_intent, :rework_completed] do
    with :ok <- exact_atom_keys(event, [:kind, :operation_id, :round, :head_sha, :target_state, :cluster_ids]),
         :ok <- valid_operation_id(event.operation_id),
         :ok <- valid_round(event.round),
         :ok <- valid_head_sha(event.head_sha),
         :ok <- valid_nonblank(event.target_state),
         {:ok, cluster_ids} <- canonical_cluster_ids(event.cluster_ids, false) do
      {:ok,
       %{
         "schema_version" => 1,
         "event" => Atom.to_string(kind),
         "operation_id" => event.operation_id,
         "round" => event.round,
         "head_sha" => event.head_sha,
         "target_state" => event.target_state,
         "cluster_ids" => cluster_ids
       }}
    end
  end

  defp event_to_wire(%{kind: :convergence_hold} = event) do
    with :ok <- exact_atom_keys(event, [:kind, :hold_id, :head_sha, :reason, :cluster_ids]),
         :ok <- valid_hold_id(event.hold_id),
         :ok <- valid_head_sha(event.head_sha),
         {:ok, reason} <- Map.fetch(@wire_reason_by_atom, event.reason),
         {:ok, cluster_ids} <- canonical_cluster_ids(event.cluster_ids, true) do
      {:ok,
       %{
         "schema_version" => 1,
         "event" => "convergence_hold",
         "hold_id" => event.hold_id,
         "head_sha" => event.head_sha,
         "reason" => reason,
         "cluster_ids" => cluster_ids
       }}
    else
      :error -> {:error, :invalid_ledger_event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_to_wire(_event), do: {:error, :invalid_ledger_event}

  defp exact_keys(value, expected) when is_map(value) do
    actual = Map.keys(value)

    cond do
      actual -- expected != [] -> {:error, :unknown_ledger_field}
      expected -- actual != [] -> {:error, :malformed_ledger_event}
      true -> :ok
    end
  end

  defp exact_atom_keys(value, expected) when is_map(value) do
    if MapSet.new(Map.keys(value)) == MapSet.new(expected),
      do: :ok,
      else: {:error, :invalid_ledger_event}
  end

  defp valid_nonblank(value) do
    if nonblank?(value), do: :ok, else: {:error, :invalid_ledger_event}
  end

  defp valid_operation_id(value), do: valid_pattern(value, @dedup_id_pattern, :invalid_operation_id)
  defp valid_hold_id(value), do: valid_pattern(value, @dedup_id_pattern, :invalid_hold_id)
  defp valid_head_sha(value), do: valid_pattern(value, @head_sha_pattern, :invalid_head_sha)

  defp valid_pattern(value, pattern, error) do
    if is_binary(value) and Regex.match?(pattern, value), do: :ok, else: {:error, error}
  end

  defp valid_round(round) do
    if is_integer(round) and round > 0, do: :ok, else: {:error, :invalid_ledger_event}
  end

  defp parse_cluster_ids(cluster_ids, allow_empty?) do
    with {:ok, canonical} <- canonical_cluster_ids(cluster_ids, allow_empty?),
         true <- canonical == cluster_ids do
      {:ok, canonical}
    else
      false -> {:error, :noncanonical_cluster_ids}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_cluster_ids(cluster_ids, allow_empty?) when is_list(cluster_ids) do
    cond do
      cluster_ids == [] and not allow_empty? ->
        {:error, :invalid_ledger_event}

      not Enum.all?(cluster_ids, &valid_cluster_id?/1) ->
        {:error, :invalid_cluster_id}

      length(cluster_ids) != length(Enum.uniq(cluster_ids)) ->
        {:error, :noncanonical_cluster_ids}

      true ->
        {:ok, Enum.sort(cluster_ids)}
    end
  end

  defp canonical_cluster_ids(_cluster_ids, _allow_empty?), do: {:error, :invalid_ledger_event}

  defp valid_cluster_id?(cluster_id), do: is_binary(cluster_id) and cluster_id =~ @cluster_id_pattern

  defp hold_reason(reason) do
    case Map.fetch(@reason_by_wire_value, reason) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_ledger_event}
    end
  end

  defp collect_events(comment_bodies, initial) do
    Enum.reduce_while(comment_bodies, {:ok, initial}, fn body, {:ok, collected} ->
      case parse_comment(body) do
        :none -> {:cont, {:ok, collected}}
        {:ok, event} -> collect_event(event, collected)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_event(%{kind: :rework_intent} = event, collected) do
    put_consistent(collected, :intents, event.operation_id, event, :contradictory_operation)
  end

  defp collect_event(%{kind: :rework_completed} = event, collected) do
    put_consistent(collected, :completions, event.operation_id, event, :contradictory_operation)
  end

  defp collect_event(%{kind: :convergence_hold} = event, collected) do
    put_consistent(collected, :holds, event.head_sha, event, :contradictory_hold)
  end

  defp put_consistent(collected, field, key, value, contradiction) do
    existing = collected[field][key]

    cond do
      is_nil(existing) ->
        {:cont, {:ok, Map.update!(collected, field, &Map.put(&1, key, value))}}

      existing == value ->
        {:cont, {:ok, collected}}

      true ->
        {:halt, {:error, contradiction}}
    end
  end

  defp validate_operation_pairs(collected) do
    Enum.reduce_while(collected.completions, :ok, fn {operation_id, completion}, :ok ->
      validate_completion_pair(collected.intents[operation_id], completion)
    end)
  end

  defp validate_completion_pair(nil, _completion),
    do: {:halt, {:error, :completion_without_intent}}

  defp validate_completion_pair(intent, completion) do
    if matching_transition?(intent, completion),
      do: {:cont, :ok},
      else: {:halt, {:error, :completion_manifest_mismatch}}
  end

  defp matching_transition?(intent, completion) do
    Map.drop(intent, [:kind]) == Map.drop(completion, [:kind])
  end

  defp validate_rounds(collected) do
    intents = Map.values(collected.intents)
    rounds = Enum.map(intents, & &1.round)
    completed_rounds = collected.completions |> Map.values() |> Enum.map(& &1.round) |> Enum.sort()
    pending_count = map_size(collected.intents) - map_size(collected.completions)

    cond do
      length(rounds) != length(Enum.uniq(rounds)) ->
        {:error, :duplicate_rework_round}

      completed_rounds != expected_completed_rounds(length(completed_rounds)) ->
        {:error, :noncontiguous_rework_rounds}

      pending_count > 1 ->
        {:error, :multiple_pending_reworks}

      pending_count == 1 and pending_round(collected) != length(completed_rounds) + 1 ->
        {:error, :invalid_pending_rework_round}

      true ->
        :ok
    end
  end

  defp pending_round(collected) do
    completed_ids = Map.keys(collected.completions) |> MapSet.new()

    collected.intents
    |> Enum.find_value(fn {operation_id, event} ->
      if MapSet.member?(completed_ids, operation_id), do: nil, else: event.round
    end)
  end

  defp expected_completed_rounds(0), do: []
  defp expected_completed_rounds(count), do: Enum.to_list(1..count)

  defp finalize_history(collected) do
    completed = collected.completions |> Map.values() |> Enum.sort_by(& &1.round)
    completed_ids = collected.completions |> Map.keys() |> MapSet.new()

    pending =
      Map.reject(collected.intents, fn {operation_id, _event} ->
        MapSet.member?(completed_ids, operation_id)
      end)

    completed_by_head =
      Enum.reduce(completed, %{}, fn event, by_head ->
        Map.update(
          by_head,
          event.head_sha,
          MapSet.new(event.cluster_ids),
          &MapSet.union(&1, MapSet.new(event.cluster_ids))
        )
      end)

    {:ok,
     %{
       rework_count: length(completed),
       pending_transitions: pending,
       last_completed_rework: List.last(completed),
       completed_cluster_ids_by_head: completed_by_head,
       holds_by_head: collected.holds
     }}
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
