defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc "Poll-cycle integration for latest-head review convergence."

  require Logger

  alias SymphonyElixir.{Config, GitHubReviewClient, ReviewConvergence, ReviewConvergenceLedger, Tracker}
  alias SymphonyElixir.Linear.Issue

  @type state :: %{optional(String.t()) => map()}

  @spec run(state()) :: state()
  def run(state) when is_map(state) do
    settings = Config.settings!().review_convergence

    if settings.enabled do
      run_with(state, settings, GitHubReviewClient, Tracker)
    else
      state
    end
  end

  @doc false
  @spec run_with(state(), struct() | map(), module(), module()) :: state()
  def run_with(state, settings, review_client, tracker) do
    monitored_states = [settings.review_state, settings.in_progress_state] |> Enum.uniq()

    case tracker.fetch_routed_issues_by_states(monitored_states) do
      {:ok, issues} ->
        routed_issues =
          Enum.filter(issues, &Issue.routable?(&1, Config.settings!().tracker.required_labels))

        active_issue_ids = MapSet.new(routed_issues, & &1.id)
        active_state = Map.take(state, MapSet.to_list(active_issue_ids))

        Enum.reduce(routed_issues, active_state, &reconcile_issue(&1, &2, settings, review_client, tracker))

      {:error, reason} ->
        Logger.warning("Review monitor failed to fetch review-state issues: #{inspect(reason)}")
        clear_known_successes(state, settings, review_client)
    end
  end

  defp reconcile_issue(%Issue{} = issue, state, settings, review_client, tracker) do
    entry =
      Map.get(state, issue.id, %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: nil,
        review_requested: false,
        waiting: false,
        fetch_failed: false,
        last_finding_fingerprint: nil
      })

    entry = Map.put(entry, :fetch_failed, false)

    case tracker.review_history(issue.id) do
      {:ok, history} ->
        history = normalize_history(history)
        fix_rounds = max(entry.fix_rounds, history.rework_count)
        convergence_history = Map.put(history, :rework_count, fix_rounds)

        entry = %{
          entry
          | dedup: MapSet.union(entry.dedup, history.dedup),
            fix_rounds: fix_rounds,
            head_sha: entry.head_sha || history[:last_head_sha]
        }

        pending_transitions = history.pending_transitions

        entry =
          entry
          |> Map.put(:pending_transitions, pending_transitions)
          |> Map.put(:convergence_history, convergence_history)

        cond do
          map_size(pending_transitions) > 0 ->
            recover_pending_transitions(
              issue,
              entry,
              state,
              settings,
              tracker,
              pending_transitions
            )

          issue.state == settings.review_state ->
            reconcile_snapshot(issue, entry, state, settings, review_client, tracker)

          true ->
            Map.delete(state, issue.id)
        end

      {:error, reason} ->
        handle_history_error(issue, entry, state, settings, review_client, tracker, reason)
    end
  end

  defp reconcile_issue(_issue, state, _settings, _review_client, _tracker), do: state

  defp handle_history_error(issue, entry, state, settings, review_client, tracker, reason) do
    pending? = map_size(entry[:pending_transitions] || %{}) > 0

    if issue.state == settings.review_state or pending? do
      wait_for_history_error(issue, entry, state, settings, review_client, tracker, reason)
    else
      Map.delete(state, issue.id)
    end
  end

  defp clear_known_successes(state, settings, review_client) do
    Map.new(state, fn {issue_id, entry} ->
      {issue_id, clear_known_success(entry, settings, review_client)}
    end)
  end

  defp clear_known_success(%{fetch_failed: true} = entry, _settings, _review_client), do: entry

  defp clear_known_success(%{head_sha: head_sha} = entry, settings, review_client)
       when is_binary(head_sha) and head_sha != "" do
    snapshot = %{current_head_sha: head_sha}

    case publish_status(
           review_client,
           settings.repository,
           snapshot,
           :error,
           "Review issue evidence unavailable; human judgment required"
         ) do
      :ok ->
        entry
        |> Map.put(:fetch_failed, true)
        |> mark_published_status(snapshot, :error)

      {:error, _reason} ->
        entry
    end
  end

  defp clear_known_success(entry, _settings, _review_client), do: entry

  defp reconcile_snapshot(issue, entry, state, settings, review_client, tracker) do
    with branch when is_binary(branch) and branch != "" <- issue.branch_name,
         {:ok, snapshot} <- review_client.snapshot(settings.repository, branch) do
      entry = invalidate_old_head(entry, snapshot.current_head_sha)
      history = entry[:convergence_history] || normalize_history(%{rework_count: entry.fix_rounds})
      decision = ReviewConvergence.evaluate(snapshot, history, settings.max_fix_rounds)
      {updated_entry, _outcome} = apply_decision(decision, issue, entry, settings, review_client, tracker, snapshot)
      Map.put(state, issue.id, updated_entry)
    else
      nil -> wait_for_human(issue, entry, settings, review_client, tracker, :missing_branch_name, state)
      "" -> wait_for_human(issue, entry, settings, review_client, tracker, :missing_branch_name, state)
      {:error, reason} -> wait_for_human(issue, entry, settings, review_client, tracker, inspect(reason), state)
    end
  end

  defp wait_for_history_error(issue, entry, state, settings, review_client, tracker, reason) do
    entry =
      case issue.branch_name do
        branch when is_binary(branch) and branch != "" ->
          case review_client.snapshot(settings.repository, branch) do
            {:ok, snapshot} -> invalidate_old_head(entry, snapshot.current_head_sha)
            {:error, _snapshot_reason} -> entry
          end

        _missing_branch ->
          entry
      end

    wait_for_human(issue, entry, settings, review_client, tracker, inspect(reason), state)
  end

  defp invalidate_old_head(%{head_sha: head_sha} = entry, current_head) when head_sha != current_head do
    %{entry | head_sha: current_head, review_requested: false, waiting: false}
  end

  defp invalidate_old_head(entry, current_head), do: Map.put(entry, :head_sha, current_head)

  defp apply_decision({:request_review, _evidence}, issue, entry, settings, review_client, _tracker, snapshot) do
    digest = ReviewConvergence.dedup_key(:review_request, issue.id, snapshot.current_head_sha, :codex)
    key = "review-request:#{issue.id}:#{snapshot.current_head_sha}:#{digest}"

    with {entry, :ok} <-
           ensure_published_status(
             entry,
             review_client,
             settings.repository,
             snapshot,
             :pending,
             "Waiting for a formal latest-head review"
           ) do
      dedup_action(entry, key, fn ->
        ensure_review_requested(review_client, settings.repository, snapshot, key)
      end)
    end
    |> then(fn {updated, result} -> {%{updated | review_requested: result == :ok}, result} end)
  end

  defp apply_decision({:rework, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    held_findings = evidence.held_findings
    key = ReviewConvergence.dedup_key(:rework, issue.id, snapshot.current_head_sha, evidence.cluster_ids)

    case ensure_published_status(
           entry,
           review_client,
           settings.repository,
           snapshot,
           :failure,
           "Unresolved verified same-PR review findings"
         ) do
      {entry, :ok} ->
        case persist_held_findings(issue, entry, tracker, snapshot, held_findings) do
          {entry, held_result} when held_result in [:ok, :deduplicated] ->
            apply_rework(issue, entry, settings, tracker, snapshot, evidence, key)

          {entry, {:error, reason}} ->
            {entry, {:error, reason}}
        end

      {entry, {:error, reason}} ->
        {entry, {:error, reason}}
    end
  end

  defp apply_decision({:hold, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    case ensure_published_status(
           entry,
           review_client,
           settings.repository,
           snapshot,
           :pending,
           "Review findings held for verified disposition"
         ) do
      {entry, :ok} ->
        persist_held_findings(issue, entry, tracker, snapshot, evidence.held_findings)
        |> then(fn {updated, result} ->
          {%{updated | waiting: result in [:ok, :deduplicated]}, result}
        end)

      {entry, {:error, reason}} ->
        {entry, {:error, reason}}
    end
  end

  defp apply_decision(
         {:convergence_hold, evidence},
         issue,
         entry,
         settings,
         review_client,
         tracker,
         snapshot
       ) do
    case ensure_published_status(
           entry,
           review_client,
           settings.repository,
           snapshot,
           :failure,
           "Review convergence is held for one team human decision"
         ) do
      {entry, :ok} ->
        apply_convergence_hold(issue, entry, settings, tracker, snapshot, evidence)

      {entry, {:error, reason}} ->
        {entry, {:error, reason}}
    end
    |> then(fn {updated, result} ->
      {%{updated | waiting: result in [:ok, :deduplicated]}, result}
    end)
  end

  defp apply_decision({:wait, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    reason = evidence[:reason] || :external_or_human_validation
    key = ReviewConvergence.dedup_key(:wait, issue.id, snapshot.current_head_sha, reason)

    with {entry, :ok} <-
           ensure_published_status(
             entry,
             review_client,
             settings.repository,
             snapshot,
             :pending,
             "Waiting for required evidence or human judgment"
           ) do
      dedup_action(entry, key, fn ->
        tracker.create_comment(issue.id, human_comment(settings, snapshot, reason, key))
      end)
    end
    |> then(fn {updated, result} ->
      {%{updated | waiting: result == :ok}, result}
    end)
  end

  defp apply_decision({:escalate, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:escalate, issue.id, snapshot.current_head_sha, evidence[:reason])

    case ensure_published_status(
           entry,
           review_client,
           settings.repository,
           snapshot,
           :failure,
           "Review did not converge; human decision required"
         ) do
      {entry, :ok} ->
        apply_escalation(issue, entry, settings, tracker, snapshot, evidence.held_findings, key)

      {entry, {:error, reason}} ->
        {entry, {:error, reason}}
    end
    |> then(fn {updated, result} -> {%{updated | waiting: result in [:ok, :deduplicated]}, result} end)
  end

  defp apply_decision({:converged, _evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:converged, issue.id, snapshot.current_head_sha, :technical)

    status_result =
      if entry[:last_published_status] == {snapshot.current_head_sha, :success} do
        :ok
      else
        publish_status(
          review_client,
          settings.repository,
          snapshot,
          :success,
          "Latest head technically converged; human merge required"
        )
      end

    case status_result do
      :ok ->
        entry
        |> mark_published_status(snapshot, :success)
        |> dedup_action(key, fn -> tracker.create_comment(issue.id, converged_comment(snapshot, key)) end)

      {:error, reason} ->
        {entry, {:error, reason}}
    end
  end

  defp apply_escalation(issue, entry, settings, tracker, snapshot, held_findings, key) do
    with {entry, held_result} when held_result in [:ok, :deduplicated] <-
           persist_held_findings(issue, entry, tracker, snapshot, held_findings) do
      dedup_action(entry, key, fn ->
        tracker.create_comment(issue.id, human_comment(settings, snapshot, :review_not_converging, key))
      end)
    end
  end

  defp apply_convergence_hold(issue, entry, settings, tracker, snapshot, evidence) do
    case evidence[:persisted_hold] do
      %{hold_id: hold_id} ->
        {%{entry | dedup: MapSet.put(entry.dedup, hold_id)}, :deduplicated}

      _new_hold ->
        cluster_ids = Enum.sort(evidence[:cluster_ids] || [])
        subject = {evidence.reason, cluster_ids}
        hold_id = ReviewConvergence.dedup_key(:convergence_hold, issue.id, snapshot.current_head_sha, subject)

        event = %{
          kind: :convergence_hold,
          hold_id: hold_id,
          head_sha: snapshot.current_head_sha,
          reason: evidence.reason,
          cluster_ids: cluster_ids
        }

        dedup_action(entry, hold_id, fn ->
          persist_convergence_hold_comment(issue, settings, tracker, snapshot, evidence, event)
        end)
    end
  end

  defp persist_convergence_hold_comment(issue, settings, tracker, snapshot, evidence, event) do
    with {:ok, comment} <- convergence_hold_comment(settings, snapshot, evidence, event) do
      tracker.create_comment(issue.id, comment)
    end
  end

  defp ensure_review_requested(review_client, repository, snapshot, key) do
    case review_client.review_request_exists?(repository, snapshot.pull_request_number, key) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        review_client.request_review(repository, snapshot.pull_request_number, key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_rework(issue, entry, settings, tracker, snapshot, evidence, key) do
    findings = evidence.same_pr_findings
    cluster_ids = evidence.cluster_ids

    {updated, comment_result} =
      dedup_action(entry, key, fn ->
        tracker.create_comment(issue.id, rework_comment(snapshot, findings, key))
      end)

    transition_key =
      ReviewConvergence.dedup_key(:state_transition, issue.id, snapshot.current_head_sha, cluster_ids)

    {updated, result, moved?} =
      cond do
        comment_result not in [:ok, :deduplicated] ->
          {updated, comment_result, false}

        MapSet.member?(updated.dedup, transition_key) ->
          {updated, :deduplicated, false}

        true ->
          transition_to_rework(
            issue,
            updated,
            settings,
            tracker,
            snapshot,
            transition_key,
            evidence.next_round,
            cluster_ids
          )
      end

    rounds = if(moved?, do: entry.fix_rounds + 1, else: entry.fix_rounds)
    {%{updated | fix_rounds: rounds, last_finding_fingerprint: cluster_ids}, result}
  end

  defp transition_to_rework(
         issue,
         entry,
         settings,
         tracker,
         snapshot,
         transition_key,
         next_round,
         cluster_ids
       ) do
    intent_key = "transition-intent:#{transition_key}"

    intent = %{
      kind: :rework_intent,
      operation_id: transition_key,
      round: next_round,
      head_sha: snapshot.current_head_sha,
      target_state: settings.in_progress_state,
      cluster_ids: cluster_ids
    }

    {entry, intent_result} =
      dedup_action(entry, intent_key, fn ->
        with {:ok, comment} <- transition_intent_comment(intent, intent_key) do
          tracker.create_comment(issue.id, comment)
        end
      end)

    if intent_result in [:ok, :deduplicated] do
      move_and_complete_transition(issue, entry, tracker, intent)
    else
      {entry, intent_result, false}
    end
  end

  defp recover_pending_transitions(issue, entry, state, settings, tracker, pending_transitions) do
    {entry, completed_count, remaining} =
      Enum.reduce(pending_transitions, {entry, 0, %{}}, fn {operation_id, intent}, {current, count, remaining} ->
        {updated, _outcome, completed?} =
          recover_pending_transition(issue, current, settings, tracker, operation_id, intent)

        if completed? do
          {updated, count + 1, remaining}
        else
          {updated, count, Map.put(remaining, operation_id, intent)}
        end
      end)

    entry =
      entry
      |> Map.put(:fix_rounds, entry.fix_rounds + completed_count)
      |> Map.put(:pending_transitions, remaining)

    Map.put(state, issue.id, entry)
  end

  defp recover_pending_transition(issue, entry, settings, tracker, operation_id, intent) do
    intent =
      intent
      |> Map.put_new(:kind, :rework_intent)
      |> Map.put_new(:operation_id, operation_id)
      |> Map.put_new(:target_state, settings.in_progress_state)

    if issue.state == intent.target_state do
      complete_transition(issue, entry, tracker, intent)
    else
      move_and_complete_transition(issue, entry, tracker, intent)
    end
  end

  defp move_and_complete_transition(issue, entry, tracker, intent) do
    with :ok <- tracker.update_issue_state(issue.id, intent.target_state),
         :ok <- verify_issue_state(tracker, issue.id, intent.target_state) do
      complete_transition(issue, entry, tracker, intent)
    else
      {:error, reason} -> {entry, {:error, reason}, false}
    end
  end

  defp verify_issue_state(tracker, issue_id, target_state) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{id: ^issue_id, state: ^target_state}]} -> :ok
      {:ok, issues} -> {:error, {:state_transition_unverified, target_state, issues}}
      {:error, reason} -> {:error, {:state_transition_verification_failed, reason}}
    end
  end

  defp complete_transition(issue, entry, tracker, intent) do
    operation_id = intent.operation_id

    {persisted, result} =
      dedup_action(entry, operation_id, fn ->
        with {:ok, comment} <- state_transition_comment(intent) do
          tracker.create_comment(issue.id, comment)
        end
      end)

    # A deduplicated completion is already represented by this entry's durable
    # history. Only a completion newly persisted in this pass consumes a round.
    {persisted, result, result == :ok}
  end

  defp dedup_action(entry, key, action) do
    if MapSet.member?(entry.dedup, key) do
      {entry, :deduplicated}
    else
      case action.() do
        :ok -> {%{entry | dedup: MapSet.put(entry.dedup, key)}, :ok}
        {:error, reason} -> {entry, {:error, reason}}
      end
    end
  end

  defp wait_for_human(issue, entry, settings, review_client, tracker, reason, state) do
    head_sha = entry.head_sha
    snapshot = %{current_head_sha: head_sha, pull_request_number: nil, required_checks: [], threads: []}
    key = ReviewConvergence.dedup_key(:wait, issue.id, head_sha, reason)

    {entry, status_result} =
      ensure_published_status(
        entry,
        review_client,
        settings.repository,
        snapshot,
        :error,
        "Review evidence unavailable; human judgment required"
      )

    {updated, _result} =
      if status_result == :ok do
        dedup_action(entry, key, fn ->
          tracker.create_comment(issue.id, human_comment(settings, snapshot, reason, key))
        end)
      else
        {entry, status_result}
      end

    Map.put(state, issue.id, %{updated | waiting: true})
  end

  defp normalize_history(history) do
    Map.merge(
      %{
        dedup: MapSet.new(),
        rework_count: 0,
        legacy_rework_count: 0,
        pending_transitions: %{},
        last_completed_rework: nil,
        completed_cluster_ids_by_head: %{},
        holds_by_head: %{},
        ledger_error: nil,
        last_head_sha: nil
      },
      history
    )
  end

  defp finding_fingerprint(findings) do
    findings
    |> Enum.map(&finding_identity/1)
    |> Enum.sort()
  end

  defp finding_identity(finding) do
    {
      finding[:thread_id],
      finding[:finding_comment_id],
      finding[:route],
      finding[:evidence_code]
    }
  end

  defp persist_held_findings(_issue, entry, _tracker, _snapshot, []), do: {entry, :ok}

  defp persist_held_findings(issue, entry, tracker, snapshot, held_findings) do
    fingerprint = finding_fingerprint(held_findings)
    key = ReviewConvergence.dedup_key(:hold, issue.id, snapshot.current_head_sha, fingerprint)

    dedup_action(entry, key, fn ->
      tracker.create_comment(issue.id, held_findings_comment(snapshot, held_findings, key))
    end)
  end

  defp publish_status(_review_client, _repository, %{current_head_sha: head}, _state, _description)
       when head in [nil, ""],
       do: :ok

  defp publish_status(review_client, repository, snapshot, state, description) do
    review_client.publish_status(repository, snapshot.current_head_sha, state, description, nil)
  end

  defp mark_published_status(entry, snapshot, state) do
    Map.put(entry, :last_published_status, {snapshot.current_head_sha, state})
  end

  defp ensure_published_status(entry, review_client, repository, snapshot, state, description) do
    if entry[:last_published_status] == {snapshot.current_head_sha, state} do
      {entry, :ok}
    else
      case publish_status(review_client, repository, snapshot, state, description) do
        :ok -> {mark_published_status(entry, snapshot, state), :ok}
        {:error, reason} -> {entry, {:error, reason}}
      end
    end
  end

  defp rework_comment(snapshot, findings, key) do
    details =
      Enum.map_join(findings, "\n", fn finding ->
        "- P#{finding.priority}: #{finding.url || finding.path || finding_identity_display(finding)}"
      end)

    """
    Review Convergence Gate found actionable latest-head findings verified for this PR.

    - PR: ##{snapshot.pull_request_number}
    - currentHeadSha: `#{snapshot.current_head_sha}`
    #{details}

    Symphony should reuse the same branch/PR and fix only these scoped findings.
    dedup-key: `#{key}`
    """
  end

  defp held_findings_comment(snapshot, findings, key) do
    details =
      Enum.map_join(findings, "\n", fn finding ->
        location = finding.url || finding.path || finding_identity_display(finding)
        "- P#{finding.priority}: `#{finding.route}` / `#{finding.evidence_code}` / #{location}"
      end)

    """
    Review Convergence Gate held review findings that lack verified same-PR ownership.

    - PR: ##{snapshot.pull_request_number}
    - currentHeadSha: `#{snapshot.current_head_sha}`
    #{details}

    The issue remains In Review. These findings require corrected trusted metadata or team human disposition; no repair round or rereview was consumed.
    dedup-key: `#{key}`
    """
  end

  defp finding_identity_display(finding) do
    "thread #{finding.thread_id || "unknown"}, comment #{finding.finding_comment_id || "unknown"}"
  end

  defp state_transition_comment(intent) do
    completed = %{intent | kind: :rework_completed}

    with {:ok, ledger_block} <- ReviewConvergenceLedger.encode(completed) do
      {:ok,
       """
       Review Convergence Gate returned this issue to In Progress for latest-head repair.

       - currentHeadSha: `#{intent.head_sha}`
       - transition-operation: `completed`
       - transition-operation-id: `#{intent.operation_id}`
       - cluster-ids: #{Enum.join(intent.cluster_ids, ", ")}
       - dedup-key: `#{intent.operation_id}`

       #{ledger_block}
       """}
    end
  end

  defp transition_intent_comment(intent, key) do
    with {:ok, ledger_block} <- ReviewConvergenceLedger.encode(intent) do
      {:ok,
       """
       Review Convergence Gate recorded a durable rework transition intent.

       - currentHeadSha: `#{intent.head_sha}`
       - target-state: `#{intent.target_state}`
       - transition-operation: `intent`
       - transition-operation-id: `#{intent.operation_id}`
       - cluster-ids: #{Enum.join(intent.cluster_ids, ", ")}
       - dedup-key: `#{key}`

       This operation is safe to resume after timeout or process restart; completion is recorded separately.

       #{ledger_block}
       """}
    end
  end

  defp convergence_hold_comment(settings, snapshot, evidence, event) do
    owner = settings.human_owner || "team owner"

    with {:ok, ledger_block} <- ReviewConvergenceLedger.encode(event) do
      {:ok,
       """
       Review Convergence Gate placed this whole issue in Convergence Hold.

       - Decision: `#{evidence.reason}`
       - Team human owner: #{owner}
       - PR/head: ##{snapshot.pull_request_number || "unknown"} / `#{snapshot.current_head_sha}`
       - cluster-ids: #{Enum.join(event.cluster_ids, ", ")}
       - Impact/risk: automated repair and rereview are paused; technical convergence is not claimed.
       - Smallest next step: the team human owner decides whether to revise scope/implementation or accept this head.

       The issue remains In Review. No state move, rereview, merge, deployment, production, permission, or secret action is authorized.
       dedup-key: `#{event.hold_id}`

       #{ledger_block}
       """}
    end
  end

  defp human_comment(settings, snapshot, reason, key) do
    owner = settings.human_owner || "team owner"

    """
    Review Convergence Gate is waiting for team human judgment (owner: #{owner}).

    - Decision: `#{reason}`
    - Option A: provide the missing evidence/approval and keep this head.
    - Option B: revise the scope or implementation, accepting another full latest-head review.
    - Impact/risk: Symphony retry is paused; technical convergence is not claimed.
    - PR/head: ##{snapshot.pull_request_number || "unknown"} / `#{snapshot.current_head_sha || "unknown"}`

    The issue remains In Review. No merge, deployment, production, permission, or secret action is authorized.
    dedup-key: `#{key}`
    """
  end

  defp converged_comment(snapshot, key) do
    """
    Review Convergence Gate reports technical convergence for PR ##{snapshot.pull_request_number}.

    - currentHeadSha = reviewedHeadSha = `#{snapshot.current_head_sha}`
    - review: `No major issues found`
    - required checks: passed
    - unresolved actionable P1-P4 threads: 0

    This is ready for human merge review; it is not merge authorization.
    dedup-key: `#{key}`
    """
  end
end
