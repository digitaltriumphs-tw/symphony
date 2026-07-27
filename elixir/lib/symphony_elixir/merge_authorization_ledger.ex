defmodule SymphonyElixir.MergeAuthorizationLedger do
  @moduledoc """
  Versioned durable authority for exact-head merge release, intent, failure, and completion.

  Every event is bound to repository, pull request, base SHA, head SHA, and operation id. Unknown
  fields, duplicate JSON keys, malformed events, and contradictory histories fail closed.
  """

  @sentinel_prefix "<!-- symphony-merge-authorization-ledger:"
  @sentinel_open "<!-- symphony-merge-authorization-ledger:v1\n"
  @sentinel_close "\n-->"
  @sha_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @operation_pattern ~r/\A[0-9a-f]{64}\z/
  @repository_pattern ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @methods ~w(merge squash rebase)
  @failure_by_wire %{
    "head_moved" => :head_moved,
    "base_moved" => :base_moved,
    "conflict" => :conflict,
    "permission_denied" => :permission_denied,
    "rate_limited" => :rate_limited,
    "github_unavailable" => :github_unavailable,
    "merge_rejected" => :merge_rejected,
    "merge_outcome_unknown" => :merge_outcome_unknown,
    "pull_request_closed" => :pull_request_closed,
    "invalid_pull_request_state" => :invalid_pull_request_state
  }
  @wire_by_failure Map.new(@failure_by_wire, fn {wire, atom} -> {atom, wire} end)

  @common_keys [
    "schema_version",
    "event",
    "operation_id",
    "repository",
    "pull_request_number",
    "base_sha",
    "head_sha"
  ]

  @type event :: map()
  @type history :: %{
          required(:releases) => %{optional(String.t()) => event()},
          required(:intents) => %{optional(String.t()) => event()},
          required(:completions) => %{optional(String.t()) => event()},
          required(:failures) => %{optional(String.t()) => event()}
        }

  @spec encode(event()) :: {:ok, String.t()} | {:error, atom()}
  def encode(event) when is_map(event) do
    with {:ok, wire} <- event_to_wire(event),
         {:ok, json} <- Jason.encode(wire) do
      {:ok, @sentinel_open <> json <> @sentinel_close}
    else
      {:error, _reason} -> {:error, :invalid_merge_event}
    end
  end

  def encode(_event), do: {:error, :invalid_merge_event}

  @spec parse_comment(String.t()) :: :none | {:ok, event()} | {:error, atom()}
  def parse_comment(body) when is_binary(body) do
    prefix_count = body |> :binary.matches(@sentinel_prefix) |> length()
    exact_count = body |> :binary.matches(@sentinel_open) |> length()

    cond do
      prefix_count == 0 -> :none
      prefix_count != 1 or exact_count != 1 -> {:error, :duplicate_merge_event}
      true -> parse_exact_block(body)
    end
  end

  def parse_comment(_body), do: {:error, :malformed_merge_event}

  @spec history([String.t()]) :: {:ok, history()} | {:error, atom()}
  def history(comment_bodies) when is_list(comment_bodies) do
    initial = %{releases: %{}, intents: %{}, completions: %{}, failures: %{}}

    with {:ok, collected} <- collect_events(comment_bodies, initial),
         :ok <- validate_history(collected) do
      {:ok, collected}
    end
  end

  def history(_comment_bodies), do: {:error, :malformed_merge_event}

  defp parse_exact_block(body) do
    [_before, rest] = String.split(body, @sentinel_open, parts: 2)

    case String.split(rest, @sentinel_close, parts: 2) do
      [json, _after] -> decode_event(json)
      _unterminated -> {:error, :malformed_merge_event}
    end
  end

  defp decode_event(json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = decoded} ->
        with {:ok, payload} <- unique_json_value(decoded),
             {:ok, event} <- wire_to_event(payload) do
          {:ok, event}
        else
          :duplicate -> {:error, :duplicate_json_key}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :malformed_merge_event}
    end
  end

  defp unique_json_value(%Jason.OrderedObject{values: members}) do
    Enum.reduce_while(members, {:ok, {MapSet.new(), %{}}}, &collect_unique_member/2)
    |> case do
      {:ok, {_keys, map}} -> {:ok, map}
      :duplicate -> :duplicate
    end
  end

  defp unique_json_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case unique_json_value(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :duplicate -> {:halt, :duplicate}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :duplicate -> :duplicate
    end
  end

  defp unique_json_value(value), do: {:ok, value}

  defp collect_unique_member({key, value}, {:ok, {keys, map}}) do
    if MapSet.member?(keys, key) do
      {:halt, :duplicate}
    else
      collect_unique_value(key, value, keys, map)
    end
  end

  defp collect_unique_value(key, value, keys, map) do
    case unique_json_value(value) do
      {:ok, normalized} ->
        {:cont, {:ok, {MapSet.put(keys, key), Map.put(map, key, normalized)}}}

      :duplicate ->
        {:halt, :duplicate}
    end
  end

  defp wire_to_event(%{"schema_version" => version}) when version != 1,
    do: {:error, :unsupported_merge_ledger_version}

  defp wire_to_event(%{"schema_version" => 1, "event" => "authorization_release"} = payload) do
    with :ok <- exact_keys(payload, @common_keys),
         {:ok, common} <- common_from_wire(payload) do
      {:ok, Map.put(common, :kind, :authorization_release)}
    end
  end

  defp wire_to_event(%{"schema_version" => 1, "event" => "merge_intent"} = payload) do
    with :ok <- exact_keys(payload, @common_keys ++ ["method"]),
         {:ok, common} <- common_from_wire(payload),
         true <- payload["method"] in @methods do
      {:ok, common |> Map.put(:kind, :merge_intent) |> Map.put(:method, payload["method"])}
    else
      false -> {:error, :invalid_merge_method}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wire_to_event(%{"schema_version" => 1, "event" => "merge_completed"} = payload) do
    with :ok <- exact_keys(payload, @common_keys ++ ["method", "merge_sha"]),
         {:ok, common} <- common_from_wire(payload),
         true <- payload["method"] in @methods,
         :ok <- valid_sha(payload["merge_sha"]) do
      {:ok,
       common
       |> Map.put(:kind, :merge_completed)
       |> Map.put(:method, payload["method"])
       |> Map.put(:merge_sha, payload["merge_sha"])}
    else
      false -> {:error, :invalid_merge_method}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wire_to_event(%{"schema_version" => 1, "event" => "merge_failed"} = payload) do
    with :ok <- exact_keys(payload, @common_keys ++ ["method", "failure"]),
         {:ok, common} <- common_from_wire(payload),
         true <- payload["method"] in @methods,
         {:ok, failure} <- Map.fetch(@failure_by_wire, payload["failure"]) do
      {:ok,
       common
       |> Map.put(:kind, :merge_failed)
       |> Map.put(:method, payload["method"])
       |> Map.put(:failure, failure)}
    else
      false -> {:error, :invalid_merge_method}
      :error -> {:error, :invalid_merge_failure}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wire_to_event(%{"schema_version" => 1}), do: {:error, :unknown_merge_event}
  defp wire_to_event(_payload), do: {:error, :malformed_merge_event}

  defp event_to_wire(%{kind: kind} = event)
       when kind in [:authorization_release, :merge_intent, :merge_completed, :merge_failed] do
    expected = expected_atom_keys(kind)

    with :ok <- exact_atom_keys(event, expected),
         {:ok, common} <- common_to_wire(event),
         {:ok, specific} <- specific_to_wire(event) do
      {:ok, Map.merge(common, specific)}
    end
  end

  defp event_to_wire(_event), do: {:error, :invalid_merge_event}

  defp common_from_wire(payload) do
    with :ok <- valid_operation_id(payload["operation_id"]),
         :ok <- valid_repository(payload["repository"]),
         :ok <- valid_pull_request_number(payload["pull_request_number"]),
         :ok <- valid_sha(payload["base_sha"]),
         :ok <- valid_sha(payload["head_sha"]) do
      {:ok,
       %{
         operation_id: payload["operation_id"],
         repository: payload["repository"],
         pull_request_number: payload["pull_request_number"],
         base_sha: payload["base_sha"],
         head_sha: payload["head_sha"]
       }}
    end
  end

  defp common_to_wire(event) do
    with :ok <- valid_operation_id(event.operation_id),
         :ok <- valid_repository(event.repository),
         :ok <- valid_pull_request_number(event.pull_request_number),
         :ok <- valid_sha(event.base_sha),
         :ok <- valid_sha(event.head_sha) do
      {:ok,
       %{
         "schema_version" => 1,
         "event" => Atom.to_string(event.kind),
         "operation_id" => event.operation_id,
         "repository" => event.repository,
         "pull_request_number" => event.pull_request_number,
         "base_sha" => event.base_sha,
         "head_sha" => event.head_sha
       }}
    end
  end

  defp specific_to_wire(%{kind: :authorization_release}), do: {:ok, %{}}

  defp specific_to_wire(%{kind: :merge_intent, method: method}) when method in @methods,
    do: {:ok, %{"method" => method}}

  defp specific_to_wire(%{kind: :merge_completed, method: method, merge_sha: merge_sha})
       when method in @methods do
    case valid_sha(merge_sha) do
      :ok -> {:ok, %{"method" => method, "merge_sha" => merge_sha}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp specific_to_wire(%{kind: :merge_failed, method: method, failure: failure})
       when method in @methods do
    case Map.fetch(@wire_by_failure, failure) do
      {:ok, wire} -> {:ok, %{"method" => method, "failure" => wire}}
      :error -> {:error, :invalid_merge_failure}
    end
  end

  defp specific_to_wire(_event), do: {:error, :invalid_merge_event}

  defp collect_events(comment_bodies, initial) do
    Enum.reduce_while(comment_bodies, {:ok, initial}, fn body, {:ok, collected} ->
      case parse_comment(body) do
        :none -> {:cont, {:ok, collected}}
        {:ok, event} -> collect_event(event, collected)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_event(%{kind: kind} = event, collected) do
    field =
      case kind do
        :authorization_release -> :releases
        :merge_intent -> :intents
        :merge_completed -> :completions
        :merge_failed -> :failures
      end

    existing = collected[field][event.operation_id]

    cond do
      is_nil(existing) -> {:cont, {:ok, Map.update!(collected, field, &Map.put(&1, event.operation_id, event))}}
      existing == event -> {:cont, {:ok, collected}}
      true -> {:halt, {:error, :contradictory_merge_event}}
    end
  end

  defp validate_history(history) do
    operation_ids =
      [:intents, :completions, :failures]
      |> Enum.flat_map(&Map.keys(history[&1]))
      |> Enum.uniq()

    Enum.reduce_while(operation_ids, :ok, fn operation_id, :ok ->
      case validate_operation_history(history, operation_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_operation_history(history, operation_id) do
    release = history.releases[operation_id]
    intent = history.intents[operation_id]
    completion = history.completions[operation_id]
    failure = history.failures[operation_id]

    with :ok <- validate_intent(release, intent),
         :ok <- validate_completion(intent, completion),
         :ok <- validate_failure(intent, failure) do
      validate_exclusive_outcome(completion, failure)
    end
  end

  defp validate_intent(nil, _intent), do: {:error, :intent_without_release}
  defp validate_intent(_release, nil), do: {:error, :intent_without_release}

  defp validate_intent(release, intent) do
    if matching_common?(release, intent), do: :ok, else: {:error, :intent_manifest_mismatch}
  end

  defp validate_completion(_intent, nil), do: :ok

  defp validate_completion(intent, completion) do
    if matching_transition?(intent, completion),
      do: :ok,
      else: {:error, :completion_manifest_mismatch}
  end

  defp validate_failure(_intent, nil), do: :ok

  defp validate_failure(intent, failure) do
    if matching_transition?(intent, failure),
      do: :ok,
      else: {:error, :failure_manifest_mismatch}
  end

  defp validate_exclusive_outcome(nil, _failure), do: :ok
  defp validate_exclusive_outcome(_completion, nil), do: :ok
  defp validate_exclusive_outcome(_completion, _failure), do: {:error, :contradictory_merge_outcome}

  defp matching_common?(left, right),
    do: Map.take(left, common_atom_keys()) == Map.take(right, common_atom_keys())

  defp matching_transition?(intent, outcome) do
    matching_common?(intent, outcome) and intent.method == outcome.method
  end

  defp common_atom_keys,
    do: [:operation_id, :repository, :pull_request_number, :base_sha, :head_sha]

  defp expected_atom_keys(:authorization_release), do: [:kind | common_atom_keys()]
  defp expected_atom_keys(:merge_intent), do: [:kind, :method | common_atom_keys()]
  defp expected_atom_keys(:merge_completed), do: [:kind, :method, :merge_sha | common_atom_keys()]
  defp expected_atom_keys(:merge_failed), do: [:kind, :method, :failure | common_atom_keys()]

  defp exact_keys(value, expected) do
    if MapSet.new(Map.keys(value)) == MapSet.new(expected),
      do: :ok,
      else: {:error, :unknown_merge_field}
  end

  defp exact_atom_keys(value, expected) do
    if MapSet.new(Map.keys(value)) == MapSet.new(expected),
      do: :ok,
      else: {:error, :invalid_merge_event}
  end

  defp valid_operation_id(value), do: valid_pattern(value, @operation_pattern, :invalid_operation_id)
  defp valid_repository(value), do: valid_pattern(value, @repository_pattern, :invalid_repository)
  defp valid_sha(value), do: valid_pattern(value, @sha_pattern, :invalid_sha)

  defp valid_pull_request_number(value) when is_integer(value) and value > 0, do: :ok
  defp valid_pull_request_number(_value), do: {:error, :invalid_pull_request_number}

  defp valid_pattern(value, pattern, error) do
    if is_binary(value) and Regex.match?(pattern, value), do: :ok, else: {:error, error}
  end
end
