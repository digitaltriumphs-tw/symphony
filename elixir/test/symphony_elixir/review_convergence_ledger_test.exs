defmodule SymphonyElixir.ReviewConvergenceLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewConvergenceLedger

  @cluster_a "symphony-review-finding-cluster:v1:992112030cba4e48b120c7f3add9d5af9a895d323af521366122dc2f824bec84"
  @cluster_b "symphony-review-finding-cluster:v1:ececaf5eaa388c3875f8e48d795e2fecbe7901ed0c9015c3ecde19c22c472504"

  test "canonical event encoding sorts cluster IDs and round-trips the versioned wire shape" do
    event = %{
      kind: :rework_intent,
      operation_id: "operation-1",
      round: 1,
      head_sha: "head-1",
      target_state: "In Progress",
      cluster_ids: [@cluster_b, @cluster_a]
    }

    assert {:ok, block} = ReviewConvergenceLedger.encode(event)
    assert block =~ "<!-- symphony-review-convergence-ledger:v1"

    assert {:ok,
            %{
              kind: :rework_intent,
              operation_id: "operation-1",
              round: 1,
              head_sha: "head-1",
              target_state: "In Progress",
              cluster_ids: [@cluster_a, @cluster_b]
            }} = ReviewConvergenceLedger.parse_comment("human-readable receipt\n\n#{block}")
  end

  test "missing sentinels are ignored while malformed, duplicated, and noncanonical wire fails closed" do
    assert :none = ReviewConvergenceLedger.parse_comment("ordinary Linear comment")

    valid =
      ledger_block(%{
        "schema_version" => 1,
        "event" => "rework_intent",
        "operation_id" => "operation-1",
        "round" => 1,
        "head_sha" => "head-1",
        "target_state" => "In Progress",
        "cluster_ids" => [@cluster_a]
      })

    assert {:error, :duplicate_ledger_event} =
             ReviewConvergenceLedger.parse_comment(valid <> "\n" <> valid)

    assert {:error, :malformed_ledger_event} =
             ReviewConvergenceLedger.parse_comment("<!-- symphony-review-convergence-ledger:v1\n{not-json}\n-->")

    assert {:error, :unsupported_ledger_version} =
             ReviewConvergenceLedger.parse_comment("<!-- symphony-review-convergence-ledger:v2\n{}\n-->")

    assert {:error, :unknown_ledger_field} =
             ReviewConvergenceLedger.parse_comment(String.replace(valid, "\"round\":1", "\"round\":1,\"extra\":true"))

    assert {:error, :noncanonical_cluster_ids} =
             ReviewConvergenceLedger.parse_comment(String.replace(valid, Jason.encode!([@cluster_a]), Jason.encode!([@cluster_b, @cluster_a])))

    duplicate_key =
      "<!-- symphony-review-convergence-ledger:v1\n" <>
        ~s|{"schema_version":1,"schema_version":1,"event":"rework_intent","operation_id":"operation-1","round":1,"head_sha":"head-1","target_state":"In Progress","cluster_ids":["#{@cluster_a}"]}| <>
        "\n-->"

    assert {:error, :malformed_ledger_event} =
             ReviewConvergenceLedger.parse_comment(duplicate_key)
  end

  test "history restores completed rounds, the last exact-head manifest, holds, and pending transitions" do
    intent_1 = event(:rework_intent, "operation-1", 1, "head-1", [@cluster_a])
    completed_1 = event(:rework_completed, "operation-1", 1, "head-1", [@cluster_a])
    intent_2 = event(:rework_intent, "operation-2", 2, "head-2", [@cluster_b])

    hold = %{
      kind: :convergence_hold,
      hold_id: "hold-head-2",
      head_sha: "head-2",
      reason: :repeated_cluster,
      cluster_ids: [@cluster_b]
    }

    bodies = Enum.map([intent_2, hold, completed_1, intent_1], &encoded_comment/1)

    assert {:ok, history} = ReviewConvergenceLedger.history(bodies)
    assert history.rework_count == 1
    assert history.last_completed_rework == completed_1
    assert history.completed_cluster_ids_by_head == %{"head-1" => MapSet.new([@cluster_a])}
    assert history.pending_transitions == %{"operation-2" => intent_2}
    assert history.holds_by_head == %{"head-2" => hold}
  end

  test "completion without a matching intent and contradictory manifests fail closed" do
    completion = event(:rework_completed, "operation-1", 1, "head-1", [@cluster_a])

    assert {:error, :completion_without_intent} =
             ReviewConvergenceLedger.history([encoded_comment(completion)])

    intent = event(:rework_intent, "operation-1", 1, "head-1", [@cluster_a])
    conflicting = event(:rework_completed, "operation-1", 1, "head-1", [@cluster_b])

    assert {:error, :completion_manifest_mismatch} =
             ReviewConvergenceLedger.history([encoded_comment(intent), encoded_comment(conflicting)])

    other_intent = event(:rework_intent, "operation-2", 1, "head-2", [@cluster_b])

    assert {:error, :duplicate_rework_round} =
             ReviewConvergenceLedger.history([encoded_comment(intent), encoded_comment(other_intent)])
  end

  defp event(kind, operation_id, round, head_sha, cluster_ids) do
    %{
      kind: kind,
      operation_id: operation_id,
      round: round,
      head_sha: head_sha,
      target_state: "In Progress",
      cluster_ids: Enum.sort(cluster_ids)
    }
  end

  defp encoded_comment(event) do
    assert {:ok, block} = ReviewConvergenceLedger.encode(event)
    "receipt\n\n#{block}"
  end

  defp ledger_block(payload) do
    "<!-- symphony-review-convergence-ledger:v1\n#{Jason.encode!(payload)}\n-->"
  end
end
