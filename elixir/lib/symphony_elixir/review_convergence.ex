defmodule SymphonyElixir.ReviewConvergence do
  @moduledoc """
  Pure policy for deciding whether a pull request's current head has technically converged.

  Technical convergence is only a handoff signal. It never authorizes merge, deployment, or a
  terminal tracker transition.
  """

  alias SymphonyElixir.{FindingRouter, ReviewFindingCluster, ScopeContract}

  @type decision ::
          {:converged, map()}
          | {:request_review, map()}
          | {:rework, map()}
          | {:hold, map()}
          | {:convergence_hold, map()}
          | {:wait, map()}

  @spec evaluate(map(), non_neg_integer(), pos_integer()) :: decision()
  def evaluate(snapshot, fix_rounds, max_fix_rounds)
      when is_map(snapshot) and is_integer(fix_rounds) and is_integer(max_fix_rounds) do
    evaluate(snapshot, empty_history(fix_rounds), max_fix_rounds)
  end

  @spec evaluate(map(), map(), pos_integer()) :: decision()
  def evaluate(snapshot, history, max_fix_rounds)
      when is_map(snapshot) and is_map(history) and is_integer(max_fix_rounds) do
    history = normalize_history(history)
    actionable = Enum.filter(snapshot[:threads] || [], &actionable_thread?/1)
    {same_pr_findings, held_findings} = route_actionable(snapshot, actionable)
    gate_evidence = evidence(snapshot, actionable, same_pr_findings, held_findings, history)

    with :continue <- current_head_gate(snapshot, gate_evidence),
         :continue <- history_gate(snapshot, history, gate_evidence),
         :continue <- waiting_gate(snapshot, gate_evidence),
         :continue <- base_gate(snapshot, gate_evidence),
         :continue <- actionable_gate(actionable, gate_evidence, history, max_fix_rounds),
         :continue <- review_gate(snapshot, gate_evidence),
         :continue <- checks_gate(snapshot, gate_evidence) do
      {:converged, gate_evidence}
    else
      decision -> decision
    end
  end

  @spec dedup_key(atom(), String.t(), String.t() | nil, term()) :: String.t()
  def dedup_key(action, issue_id, head_sha, subject) do
    :crypto.hash(:sha256, :erlang.term_to_binary({action, issue_id, head_sha, subject}))
    |> Base.encode16(case: :lower)
  end

  @spec actionable_thread?(map()) :: boolean()
  def actionable_thread?(thread) when is_map(thread) do
    thread[:resolved] != true and thread[:priority] in 1..4
  end

  def actionable_thread?(_thread), do: false

  defp waiting_gate(%{waiting_reason: reason}, evidence) when not is_nil(reason),
    do: {:wait, Map.put(evidence, :reason, reason)}

  defp waiting_gate(_snapshot, _evidence), do: :continue

  defp current_head_gate(%{current_head_sha: head}, evidence) when head in [nil, ""] do
    {:wait, Map.put(evidence, :reason, :missing_current_head)}
  end

  defp current_head_gate(_snapshot, _evidence), do: :continue

  defp base_gate(snapshot, evidence) do
    if base_verification_failed?(snapshot) do
      {:wait, Map.put(evidence, :reason, :base_unverified)}
    else
      :continue
    end
  end

  defp history_gate(snapshot, history, evidence) do
    persisted_hold = history.holds_by_head[snapshot[:current_head_sha]]

    cond do
      not is_nil(history.ledger_error) ->
        convergence_hold(evidence, :invalid_ledger, [], %{ledger_error: history.ledger_error})

      history.legacy_rework_count > 0 ->
        convergence_hold(evidence, :legacy_rework_without_manifest, [], %{
          legacy_rework_count: history.legacy_rework_count
        })

      not is_nil(persisted_hold) ->
        {:convergence_hold,
         evidence
         |> Map.put(:reason, :persisted_convergence_hold)
         |> Map.put(:cluster_ids, persisted_hold.cluster_ids)
         |> Map.put(:persisted_hold, persisted_hold)}

      true ->
        :continue
    end
  end

  defp actionable_gate([], _evidence, _history, _max_fix_rounds), do: :continue

  defp actionable_gate(_actionable, %{same_pr_findings: []} = evidence, _history, _max_fix_rounds) do
    {:hold, Map.put(evidence, :reason, :no_verified_same_pr_findings)}
  end

  defp actionable_gate(_actionable, evidence, history, max_fix_rounds) do
    case ReviewFindingCluster.cluster(evidence.same_pr_findings) do
      {:ok, clusters} ->
        cluster_ids = Enum.map(clusters, & &1.cluster_id)
        completed_ids = completed_cluster_ids(history, evidence.current_head_sha)
        repeated_ids = cluster_ids |> MapSet.new() |> MapSet.intersection(completed_ids) |> MapSet.to_list() |> Enum.sort()

        clustered_evidence =
          evidence
          |> Map.put(:clusters, clusters)
          |> Map.put(:cluster_ids, cluster_ids)
          |> Map.put(:next_round, history.rework_count + 1)

        cond do
          repeated_ids != [] ->
            convergence_hold(clustered_evidence, :repeated_cluster, cluster_ids, %{
              repeated_cluster_ids: repeated_ids
            })

          history.rework_count >= max_fix_rounds ->
            convergence_hold(clustered_evidence, :fix_round_budget_exhausted, cluster_ids, %{
              fix_rounds: history.rework_count,
              max_fix_rounds: max_fix_rounds
            })

          true ->
            {:rework, clustered_evidence}
        end
    end
  end

  defp convergence_hold(evidence, reason, cluster_ids, extra) do
    {:convergence_hold,
     evidence
     |> Map.put(:reason, reason)
     |> Map.put(:cluster_ids, Enum.sort(cluster_ids))
     |> Map.merge(extra)}
  end

  defp completed_cluster_ids(history, head_sha) do
    history.completed_cluster_ids_by_head
    |> Map.get(head_sha, MapSet.new())
    |> to_map_set()
    |> then(fn completed ->
      case history.last_completed_rework do
        %{cluster_ids: cluster_ids} ->
          MapSet.union(completed, MapSet.new(cluster_ids))

        _other ->
          completed
      end
    end)
  end

  defp to_map_set(%MapSet{} = values), do: values
  defp to_map_set(values) when is_list(values), do: MapSet.new(values)
  defp to_map_set(_values), do: MapSet.new()

  defp review_gate(snapshot, evidence) do
    if snapshot[:reviewed_head_sha] == snapshot[:current_head_sha] and
         snapshot[:review_result] == :no_major_issues do
      :continue
    else
      {:request_review, evidence}
    end
  end

  defp checks_gate(snapshot, evidence) do
    if checks_passed?(snapshot[:required_checks] || []) do
      :continue
    else
      {:wait, Map.put(evidence, :reason, :required_checks_not_passed)}
    end
  end

  defp checks_passed?(checks) do
    Enum.all?(checks, fn check -> check[:state] in [:success, :skipped, :neutral] end)
  end

  defp base_verification_failed?(snapshot) do
    snapshot[:base_verification_required] == true and snapshot[:base_verification] != :verified
  end

  defp route_actionable(_snapshot, []), do: {[], []}

  defp route_actionable(snapshot, actionable) do
    routed =
      case snapshot[:scope_contract] do
        {:ok, %ScopeContract{} = contract} ->
          binding = %{
            base_sha: snapshot[:base_ref_oid],
            head_sha: snapshot[:current_head_sha]
          }

          Enum.map(actionable, &FindingRouter.route(contract, &1, binding))

        _invalid_scope_contract ->
          Enum.map(actionable, &invalid_scope_contract_record/1)
      end

    Enum.split_with(routed, &(&1.route == :same_pr))
  end

  defp invalid_scope_contract_record(finding) do
    %{
      thread_id: finding[:thread_id],
      finding_comment_id: finding[:finding_comment_id],
      route: :human_hold,
      evidence_code: :invalid_scope_contract,
      evidence_display: "PR Scope Contract is invalid or missing",
      original_kind: nil,
      priority: finding[:priority],
      path: finding[:path],
      url: finding[:url],
      evidence: %{}
    }
  end

  defp evidence(snapshot, actionable, same_pr_findings, held_findings, history) do
    %{
      current_head_sha: snapshot[:current_head_sha],
      reviewed_head_sha: snapshot[:reviewed_head_sha],
      review_result: snapshot[:review_result],
      base_ref_oid: snapshot[:base_ref_oid],
      base_verification: snapshot[:base_verification],
      required_checks: snapshot[:required_checks] || [],
      actionable_threads: actionable,
      same_pr_findings: same_pr_findings,
      held_findings: held_findings,
      convergence_history: history
    }
  end

  defp empty_history(rework_count) do
    %{
      rework_count: rework_count,
      legacy_rework_count: 0,
      last_completed_rework: nil,
      completed_cluster_ids_by_head: %{},
      holds_by_head: %{},
      ledger_error: nil
    }
  end

  defp normalize_history(history) do
    Map.merge(empty_history(0), history)
  end
end
