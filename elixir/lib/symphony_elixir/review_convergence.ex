defmodule SymphonyElixir.ReviewConvergence do
  @moduledoc """
  Pure policy for deciding whether a pull request's current head has technically converged.

  Technical convergence is only a handoff signal. It never authorizes merge, deployment, or a
  terminal tracker transition.
  """

  alias SymphonyElixir.{FindingRouter, ScopeContract}

  @type decision ::
          {:converged, map()}
          | {:request_review, map()}
          | {:rework, map()}
          | {:hold, map()}
          | {:wait, map()}
          | {:escalate, map()}

  @spec evaluate(map(), non_neg_integer(), pos_integer()) :: decision()
  def evaluate(snapshot, fix_rounds, max_fix_rounds)
      when is_map(snapshot) and is_integer(fix_rounds) and is_integer(max_fix_rounds) do
    actionable = Enum.filter(snapshot[:threads] || [], &actionable_thread?/1)
    {same_pr_findings, held_findings} = route_actionable(snapshot, actionable)
    gate_evidence = evidence(snapshot, actionable, same_pr_findings, held_findings)

    with :continue <- waiting_gate(snapshot, gate_evidence),
         :continue <- current_head_gate(snapshot, gate_evidence),
         :continue <- base_gate(snapshot, gate_evidence),
         :continue <- actionable_gate(actionable, gate_evidence, fix_rounds, max_fix_rounds),
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

  defp actionable_gate([], _evidence, _fix_rounds, _max_fix_rounds), do: :continue

  defp actionable_gate(_actionable, evidence, fix_rounds, max_fix_rounds) do
    cond do
      evidence.same_pr_findings == [] ->
        {:hold, Map.put(evidence, :reason, :no_verified_same_pr_findings)}

      fix_rounds >= max_fix_rounds ->
        {:escalate, Map.put(evidence, :reason, :review_not_converging)}

      true ->
        {:rework, evidence}
    end
  end

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

  defp evidence(snapshot, actionable, same_pr_findings, held_findings) do
    %{
      current_head_sha: snapshot[:current_head_sha],
      reviewed_head_sha: snapshot[:reviewed_head_sha],
      review_result: snapshot[:review_result],
      base_ref_oid: snapshot[:base_ref_oid],
      base_verification: snapshot[:base_verification],
      required_checks: snapshot[:required_checks] || [],
      actionable_threads: actionable,
      same_pr_findings: same_pr_findings,
      held_findings: held_findings
    }
  end
end
