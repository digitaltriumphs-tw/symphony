defmodule SymphonyElixir.MergeExecutor do
  @moduledoc """
  Executes an authorized merge as a durable, exact-head operation.

  Intent is persisted before GitHub is called. Completion and typed failure are persisted
  separately so poll retries and process restarts do not issue a second merge.
  """

  alias SymphonyElixir.{MergeAuthorization, MergeAuthorizationLedger}

  @type entry :: map()
  @type history :: map()

  @spec reconcile(map(), entry(), map(), module(), module(), map()) :: entry()
  def reconcile(issue, entry, settings, review_client, tracker, snapshot) do
    merge_settings = merge_settings(settings)

    cond do
      terminal_for_head?(entry[:merge], snapshot.current_head_sha) ->
        entry

      pending_terminal_receipt?(entry[:merge]) ->
        retry_pending_terminal_receipt(issue, entry, tracker)

      merge_settings.enabled != true ->
        Map.put(entry, :merge, default_state(settings, snapshot))

      true ->
        merge_history = history_for_entry(entry)
        release = MergeAuthorization.release_event(issue.id, snapshot)

        case ensure_event(issue, entry, tracker, release, merge_history) do
          {entry, merge_history, result} when result in [:ok, :durable] ->
            authorize_released(
              issue,
              entry,
              merge_settings,
              review_client,
              tracker,
              settings.repository,
              snapshot,
              merge_history
            )

          {entry, _history, {:error, reason}} ->
            pending =
              default_state(settings, snapshot)
              |> Map.put(:reason, :release_persist_failed)
              |> Map.put(:failure, normalize_failure(reason))
              |> Map.put(:pending_receipt, release)

            Map.put(entry, :merge, pending)
        end
    end
  end

  defp authorize_released(
         issue,
         entry,
         merge_settings,
         review_client,
         tracker,
         repository,
         snapshot,
         merge_history
       ) do
    receipt = fetch_ruleset_receipt(review_client, repository, snapshot)

    authorization =
      MergeAuthorization.evaluate(%{
        settings: merge_settings,
        issue_id: issue.id,
        snapshot: snapshot,
        convergence_history: entry[:convergence_history] || %{},
        merge_history: merge_history,
        ruleset_receipt: receipt
      })

    entry = Map.put(entry, :merge, authorization)

    if authorization.status == :merge_ready do
      execute(issue, entry, tracker, review_client, snapshot, merge_history, authorization)
    else
      entry
    end
  end

  @spec recover(map(), entry(), map(), module(), module(), history()) ::
          {:resolved, entry()} | {:open, entry()}
  def recover(issue, entry, _settings, review_client, tracker, history) do
    intent = pending_intent(history)
    merge_history = normalize_history(history[:merge])
    authorization = state_from_event(intent, :merge_ready, nil, merge_history)
    entry = Map.put(entry, :merge, authorization)

    case review_client.pull_request_state(intent.repository, intent.pull_request_number) do
      {:ok, %{base_sha: base_sha}} when base_sha != intent.base_sha ->
        {:resolved,
         record_failure(
           issue,
           entry,
           tracker,
           merge_history,
           authorization,
           intent,
           :base_moved
         )}

      {:ok, %{head_sha: head_sha}} when head_sha != intent.head_sha ->
        {:resolved,
         record_failure(
           issue,
           entry,
           tracker,
           merge_history,
           authorization,
           intent,
           :head_moved
         )}

      {:ok, %{status: :merged, merge_sha: merge_sha}} ->
        {:resolved,
         record_completion(
           issue,
           entry,
           tracker,
           merge_history,
           authorization,
           intent,
           merge_sha
         )}

      {:ok, %{status: :open}} ->
        {:open, entry}

      {:ok, _closed} ->
        {:resolved,
         record_failure(
           issue,
           entry,
           tracker,
           merge_history,
           authorization,
           intent,
           :pull_request_closed
         )}

      {:error, reason} ->
        {:resolved,
         record_failure(
           issue,
           entry,
           tracker,
           merge_history,
           authorization,
           intent,
           normalize_failure(reason)
         )}
    end
  end

  @spec pending_intent(history()) :: map() | nil
  def pending_intent(history) when is_map(history) do
    merge = normalize_history(history[:merge])

    Enum.find_value(merge.intents, fn {operation_id, intent} ->
      if is_nil(merge.completions[operation_id]) and is_nil(merge.failures[operation_id]),
        do: intent
    end)
  end

  @spec restore(entry(), history()) :: entry()
  def restore(entry, history) when is_map(entry) and is_map(history) do
    merge = normalize_history(history[:merge])

    cond do
      match?(
        %MergeAuthorization.State{pending_receipt: pending} when not is_nil(pending),
        entry[:merge]
      ) ->
        entry

      event = latest_event(merge.completions) ->
        Map.put(entry, :merge, state_from_event(event, :merged, nil, merge))

      event = latest_event(merge.failures) ->
        Map.put(entry, :merge, state_from_event(event, :merge_failed, event.failure, merge))

      event = latest_event(merge.intents) ->
        Map.put(entry, :merge, state_from_event(event, :merge_ready, nil, merge))

      true ->
        entry
    end
  end

  @spec default_state(map(), map()) :: MergeAuthorization.State.t()
  def default_state(settings, snapshot \\ %{}) do
    merge_settings = merge_settings(settings)

    struct(MergeAuthorization.State,
      status: :holding,
      reason: if(merge_settings[:enabled] == true, do: :release_unverified, else: :disabled),
      repository: snapshot[:repository] || settings[:repository],
      pull_request_number: snapshot[:pull_request_number],
      base_sha: snapshot[:base_ref_oid],
      head_sha: snapshot[:current_head_sha],
      method: merge_settings[:method],
      receipts: []
    )
  end

  defp execute(issue, entry, tracker, review_client, snapshot, merge_history, authorization) do
    operation_id = authorization.operation_id
    intent = merge_history.intents[operation_id] || intent_event(authorization)

    case ensure_event(issue, entry, tracker, intent, merge_history) do
      {entry, merge_history, result} when result in [:ok, :durable] ->
        authorization =
          Map.put(
            authorization,
            :receipts,
            receipts(merge_history, authorization.operation_id)
          )

        entry = Map.put(entry, :merge, authorization)

        verify_and_merge(
          issue,
          entry,
          tracker,
          review_client,
          snapshot,
          merge_history,
          authorization,
          intent
        )

      {entry, _history, {:error, reason}} ->
        pending =
          authorization
          |> Map.put(:reason, :intent_persist_failed)
          |> Map.put(:failure, normalize_failure(reason))
          |> Map.put(:pending_receipt, intent)

        Map.put(entry, :merge, pending)
    end
  end

  defp verify_and_merge(
         issue,
         entry,
         tracker,
         review_client,
         snapshot,
         merge_history,
         authorization,
         intent
       ) do
    case review_client.pull_request_state(snapshot.repository, snapshot.pull_request_number) do
      {:ok, pull_request} ->
        cond do
          pull_request.base_sha != snapshot.base_ref_oid ->
            record_failure(
              issue,
              entry,
              tracker,
              merge_history,
              authorization,
              intent,
              :base_moved
            )

          pull_request.head_sha != snapshot.current_head_sha ->
            record_failure(
              issue,
              entry,
              tracker,
              merge_history,
              authorization,
              intent,
              :head_moved
            )

          pull_request.status == :merged ->
            record_completion(
              issue,
              entry,
              tracker,
              merge_history,
              authorization,
              intent,
              pull_request.merge_sha
            )

          pull_request.status == :open ->
            merge_exact_head(
              issue,
              entry,
              tracker,
              review_client,
              snapshot,
              merge_history,
              authorization,
              intent
            )

          true ->
            record_failure(
              issue,
              entry,
              tracker,
              merge_history,
              authorization,
              intent,
              :pull_request_closed
            )
        end

      {:error, reason} ->
        record_failure(
          issue,
          entry,
          tracker,
          merge_history,
          authorization,
          intent,
          normalize_failure(reason)
        )
    end
  end

  defp merge_exact_head(
         issue,
         entry,
         tracker,
         review_client,
         snapshot,
         merge_history,
         authorization,
         intent
       ) do
    case review_client.merge_pull_request(
           snapshot.repository,
           snapshot.pull_request_number,
           snapshot.current_head_sha,
           authorization.method
         ) do
      {:ok, %{merged: true, merge_sha: merge_sha}} ->
        record_completion(
          issue,
          entry,
          tracker,
          merge_history,
          authorization,
          intent,
          merge_sha
        )

      {:error, reason} ->
        record_failure(
          issue,
          entry,
          tracker,
          merge_history,
          authorization,
          intent,
          normalize_failure(reason)
        )
    end
  end

  defp record_completion(
         issue,
         entry,
         tracker,
         merge_history,
         authorization,
         intent,
         merge_sha
       ) do
    completed =
      intent
      |> Map.put(:kind, :merge_completed)
      |> Map.put(:merge_sha, merge_sha)

    case ensure_event(issue, entry, tracker, completed, merge_history) do
      {entry, merge_history, result} when result in [:ok, :durable] ->
        merge =
          authorization
          |> Map.put(:status, :merged)
          |> Map.put(:reason, nil)
          |> Map.put(:failure, nil)
          |> Map.put(:pending_receipt, nil)
          |> Map.put(:receipts, receipts(merge_history, authorization.operation_id))

        Map.put(entry, :merge, merge)

      {entry, _history, {:error, _reason}} ->
        merge =
          authorization
          |> Map.put(:status, :merged)
          |> Map.put(:reason, :completion_persist_failed)
          |> Map.put(:failure, nil)
          |> Map.put(:pending_receipt, completed)

        Map.put(entry, :merge, merge)
    end
  end

  defp record_failure(
         issue,
         entry,
         tracker,
         merge_history,
         authorization,
         intent,
         failure
       ) do
    failed =
      intent
      |> Map.put(:kind, :merge_failed)
      |> Map.put(:failure, failure)

    case ensure_event(issue, entry, tracker, failed, merge_history) do
      {entry, merge_history, result} when result in [:ok, :durable] ->
        merge =
          authorization
          |> Map.put(:status, :merge_failed)
          |> Map.put(:reason, :github_merge_failed)
          |> Map.put(:failure, failure)
          |> Map.put(:pending_receipt, nil)
          |> Map.put(:receipts, receipts(merge_history, authorization.operation_id))

        Map.put(entry, :merge, merge)

      {entry, _history, {:error, _reason}} ->
        merge =
          authorization
          |> Map.put(:status, :merge_failed)
          |> Map.put(:reason, :failure_persist_failed)
          |> Map.put(:failure, failure)
          |> Map.put(:pending_receipt, failed)

        Map.put(entry, :merge, merge)
    end
  end

  defp ensure_event(issue, entry, tracker, event, merge_history) do
    field = history_field(event.kind)
    operation_id = event.operation_id

    cond do
      merge_history[field][operation_id] == event ->
        {remember_receipt(entry, event), merge_history, :durable}

      not is_nil(merge_history[field][operation_id]) ->
        {entry, merge_history, {:error, :contradictory_merge_event}}

      not event_prerequisite?(event, merge_history) ->
        {entry, merge_history, {:error, :merge_event_prerequisite_missing}}

      true ->
        persist_new_event(issue, entry, tracker, event, merge_history, field)
    end
  end

  defp persist_new_event(issue, entry, tracker, event, merge_history, field) do
    key = "merge-ledger:#{event.kind}:#{event.operation_id}"

    if MapSet.member?(entry.dedup, key) do
      {entry, merge_history, {:error, :merge_receipt_unverified}}
    else
      with {:ok, ledger_block} <- MergeAuthorizationLedger.encode(event),
           :ok <- tracker.create_comment(issue.id, event_comment(event, key, ledger_block)) do
        entry =
          entry
          |> Map.put(:dedup, MapSet.put(entry.dedup, key))
          |> remember_receipt(event)

        history = put_in(merge_history, [field, event.operation_id], event)
        {entry, history, :ok}
      else
        {:error, reason} -> {entry, merge_history, {:error, reason}}
      end
    end
  end

  defp retry_pending_terminal_receipt(issue, entry, tracker) do
    event = entry.merge.pending_receipt
    history = history_for_entry(entry)

    case ensure_event(issue, entry, tracker, event, history) do
      {entry, history, result} when result in [:ok, :durable] ->
        status = if event.kind == :merge_completed, do: :merged, else: :merge_failed
        failure = if event.kind == :merge_failed, do: event.failure

        merge =
          entry.merge
          |> Map.put(:status, status)
          |> Map.put(:reason, nil)
          |> Map.put(:failure, failure)
          |> Map.put(:pending_receipt, nil)
          |> Map.put(:receipts, receipts(history, event.operation_id))

        Map.put(entry, :merge, merge)

      {entry, _history, {:error, _reason}} ->
        entry
    end
  end

  defp pending_terminal_receipt?(%MergeAuthorization.State{
         pending_receipt: %{kind: kind}
       })
       when kind in [:merge_completed, :merge_failed],
       do: true

  defp pending_terminal_receipt?(_merge), do: false

  defp fetch_ruleset_receipt(review_client, repository, snapshot) do
    case review_client.ruleset_receipt(repository, snapshot.base_ref_name) do
      {:ok, receipt} ->
        receipt

      {:error, reason} ->
        %{
          status: :unverified,
          repository: repository,
          base_ref: snapshot.base_ref_name,
          source: nil,
          required_context: nil,
          strict: false,
          reason: reason
        }
    end
  end

  defp history_for_entry(entry) do
    history =
      entry
      |> Map.get(:convergence_history, %{})
      |> Map.get(:merge, empty_history())
      |> normalize_history()

    receipts =
      case entry[:merge] do
        %{receipts: receipts} -> receipts
        _missing -> []
      end

    receipts
    |> Enum.reduce(history, &put_history_event(&2, &1))
  end

  defp remember_receipt(entry, event) do
    merge = entry[:merge] || struct(MergeAuthorization.State, status: :holding)
    receipts = Enum.uniq_by([event | merge.receipts], &{&1.kind, &1.operation_id})
    Map.put(entry, :merge, %{merge | receipts: receipts})
  end

  defp put_history_event(history, %{kind: kind, operation_id: operation_id} = event) do
    put_in(history, [history_field(kind), operation_id], event)
  end

  defp put_history_event(history, _event), do: history

  defp history_field(:authorization_release), do: :releases
  defp history_field(:merge_intent), do: :intents
  defp history_field(:merge_completed), do: :completions
  defp history_field(:merge_failed), do: :failures

  defp event_prerequisite?(%{kind: :authorization_release}, _history), do: true

  defp event_prerequisite?(%{kind: :merge_intent} = event, history) do
    matching_common?(history.releases[event.operation_id], event)
  end

  defp event_prerequisite?(%{kind: kind} = event, history)
       when kind in [:merge_completed, :merge_failed] do
    matching_transition?(history.intents[event.operation_id], event)
  end

  defp matching_common?(nil, _event), do: false

  defp matching_common?(left, right) do
    keys = [:operation_id, :repository, :pull_request_number, :base_sha, :head_sha]
    Map.take(left, keys) == Map.take(right, keys)
  end

  defp matching_transition?(nil, _event), do: false

  defp matching_transition?(intent, event) do
    matching_common?(intent, event) and intent.method == event.method
  end

  defp normalize_history(history) when is_map(history), do: Map.merge(empty_history(), history)
  defp normalize_history(_history), do: empty_history(:invalid_history)

  defp empty_history(error \\ nil),
    do: %{releases: %{}, intents: %{}, completions: %{}, failures: %{}, ledger_error: error}

  defp latest_event(events) when is_map(events), do: events |> Map.values() |> List.last()

  defp state_from_event(event, status, failure, history) do
    struct(MergeAuthorization.State,
      status: status,
      reason: if(status == :merge_failed, do: :github_merge_failed),
      repository: event.repository,
      pull_request_number: event.pull_request_number,
      base_sha: event.base_sha,
      head_sha: event.head_sha,
      operation_id: event.operation_id,
      method: event[:method],
      failure: failure,
      receipts: receipts(history, event.operation_id)
    )
  end

  defp receipts(history, operation_id) do
    [
      history.releases[operation_id],
      history.intents[operation_id],
      history.failures[operation_id],
      history.completions[operation_id]
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp intent_event(authorization) do
    %{
      kind: :merge_intent,
      operation_id: authorization.operation_id,
      repository: authorization.repository,
      pull_request_number: authorization.pull_request_number,
      base_sha: authorization.base_sha,
      head_sha: authorization.head_sha,
      method: authorization.method
    }
  end

  defp merge_settings(settings) do
    case settings[:merge_authorization] do
      %{} = merge -> merge
      _missing -> %{enabled: false, method: "squash"}
    end
  end

  defp terminal_for_head?(
         %MergeAuthorization.State{
           status: status,
           head_sha: head_sha,
           pending_receipt: nil
         },
         head_sha
       )
       when status in [:merge_failed, :merged],
       do: true

  defp terminal_for_head?(_merge, _head_sha), do: false

  defp normalize_failure(reason)
       when reason in [
              :head_moved,
              :base_moved,
              :conflict,
              :permission_denied,
              :rate_limited,
              :github_unavailable,
              :merge_rejected,
              :pull_request_closed,
              :invalid_pull_request_state
            ],
       do: reason

  defp normalize_failure(_reason), do: :github_unavailable

  defp event_comment(event, key, ledger_block) do
    """
    Symphony recorded durable exact-head merge evidence.

    - event: #{event.kind}
    - repository / PR: #{event.repository} / ##{event.pull_request_number}
    - baseSha: #{event.base_sha}
    - currentHeadSha: #{event.head_sha}
    - operation-id: #{event.operation_id}
    - dedup-key: #{key}

    #{ledger_block}
    """
  end
end
