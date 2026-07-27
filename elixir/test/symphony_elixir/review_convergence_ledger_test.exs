defmodule SymphonyElixir.ReviewConvergenceLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewConvergenceLedger

  @cluster_a "symphony-review-finding-cluster:v1:992112030cba4e48b120c7f3add9d5af9a895d323af521366122dc2f824bec84"
  @cluster_b "symphony-review-finding-cluster:v1:ececaf5eaa388c3875f8e48d795e2fecbe7901ed0c9015c3ecde19c22c472504"
  @operation_1 String.duplicate("1", 64)
  @operation_2 String.duplicate("2", 64)
  @hold_id String.duplicate("3", 64)
  @head_1 String.duplicate("a", 40)
  @head_2 String.duplicate("b", 64)

  test "canonical event encoding sorts cluster IDs and round-trips the versioned wire shape" do
    event = %{
      kind: :rework_intent,
      operation_id: @operation_1,
      round: 1,
      head_sha: @head_1,
      target_state: "In Progress",
      cluster_ids: [@cluster_b, @cluster_a]
    }

    assert {:ok, block} = ReviewConvergenceLedger.encode(event)
    assert block =~ "<!-- symphony-review-convergence-ledger:v1"

    assert {:ok,
            %{
              kind: :rework_intent,
              operation_id: @operation_1,
              round: 1,
              head_sha: @head_1,
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
        "operation_id" => @operation_1,
        "round" => 1,
        "head_sha" => @head_1,
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
        ~s|{"schema_version":1,"schema_version":1,"event":"rework_intent","operation_id":"#{@operation_1}","round":1,"head_sha":"#{@head_1}","target_state":"In Progress","cluster_ids":["#{@cluster_a}"]}| <>
        "\n-->"

    assert {:error, :malformed_ledger_event} =
             ReviewConvergenceLedger.parse_comment(duplicate_key)
  end

  test "transition and hold identities reject noncanonical SHA and dedup IDs" do
    valid_transition =
      ledger_block(%{
        "schema_version" => 1,
        "event" => "rework_intent",
        "operation_id" => @operation_1,
        "round" => 1,
        "head_sha" => @head_1,
        "target_state" => "In Progress",
        "cluster_ids" => [@cluster_a]
      })

    assert {:error, :invalid_operation_id} =
             valid_transition
             |> String.replace(@operation_1, String.duplicate("A", 64))
             |> ReviewConvergenceLedger.parse_comment()

    assert {:error, :invalid_head_sha} =
             valid_transition
             |> String.replace(@head_1, String.duplicate("A", 40))
             |> ReviewConvergenceLedger.parse_comment()

    assert {:error, :invalid_head_sha} =
             valid_transition
             |> String.replace(@head_1, String.duplicate("a", 39))
             |> ReviewConvergenceLedger.parse_comment()

    valid_hold =
      ledger_block(%{
        "schema_version" => 1,
        "event" => "convergence_hold",
        "hold_id" => @hold_id,
        "head_sha" => @head_2,
        "reason" => "repeated_cluster",
        "cluster_ids" => [@cluster_a]
      })

    assert {:error, :invalid_hold_id} =
             valid_hold
             |> String.replace(@hold_id, String.duplicate("3", 63))
             |> ReviewConvergenceLedger.parse_comment()

    assert {:ok, %{head_sha: @head_2}} = ReviewConvergenceLedger.parse_comment(valid_hold)
  end

  test "public entrypoints reject non-wire input and unterminated comments" do
    cases = [
      {fn -> ReviewConvergenceLedger.encode(:not_an_event) end, {:error, :invalid_ledger_event}},
      {fn -> ReviewConvergenceLedger.parse_comment(:not_a_comment) end, {:error, :malformed_ledger_event}},
      {fn -> ReviewConvergenceLedger.history(:not_comment_bodies) end, {:error, :malformed_ledger_event}},
      {fn ->
         ReviewConvergenceLedger.parse_comment("<!-- symphony-review-convergence-ledger:v1\n{}")
       end, {:error, :malformed_ledger_event}}
    ]

    Enum.each(cases, fn {operation, expected} -> assert operation.() == expected end)
  end

  test "wire decoding rejects nested duplicates and unsupported event shapes" do
    nested_duplicate =
      ledger_json(~s|{"schema_version":1,"event":"rework_intent","operation_id":"#{@operation_1}","round":1,"head_sha":"#{@head_1}","target_state":"In Progress","cluster_ids":[{"key":1,"key":2}]}|)

    cases = [
      {nested_duplicate, :malformed_ledger_event},
      {ledger_block(%{"schema_version" => 2, "event" => "rework_intent"}), :unsupported_ledger_version},
      {ledger_block(%{"schema_version" => 1, "event" => "unknown"}), :unknown_ledger_event},
      {ledger_block(%{}), :malformed_ledger_event},
      {ledger_block(%{
         "schema_version" => 1,
         "event" => "convergence_hold",
         "hold_id" => @hold_id,
         "head_sha" => @head_1,
         "reason" => "unknown",
         "cluster_ids" => []
       }), :invalid_ledger_event},
      {ledger_block(%{
         "schema_version" => 1,
         "event" => "rework_intent",
         "operation_id" => @operation_1,
         "round" => 1,
         "head_sha" => @head_1,
         "target_state" => "In Progress",
         "cluster_ids" => %{}
       }), :invalid_ledger_event}
    ]

    Enum.each(cases, fn {comment, expected_error} ->
      assert ReviewConvergenceLedger.parse_comment(comment) == {:error, expected_error}
    end)
  end

  test "event encoding rejects unsupported maps and invalid hold fields" do
    hold = %{
      kind: :convergence_hold,
      hold_id: @hold_id,
      head_sha: @head_1,
      reason: :repeated_cluster,
      cluster_ids: []
    }

    cases = [
      {%{hold | reason: :unknown}, :invalid_ledger_event},
      {%{hold | hold_id: "invalid"}, :invalid_hold_id},
      {%{kind: :unknown}, :invalid_ledger_event}
    ]

    Enum.each(cases, fn {event, expected_error} ->
      assert ReviewConvergenceLedger.encode(event) == {:error, expected_error}
    end)
  end

  test "history restores completed rounds, the last exact-head manifest, holds, and pending transitions" do
    intent_1 = event(:rework_intent, @operation_1, 1, @head_1, [@cluster_a])
    completed_1 = event(:rework_completed, @operation_1, 1, @head_1, [@cluster_a])
    intent_2 = event(:rework_intent, @operation_2, 2, @head_2, [@cluster_b])

    hold = %{
      kind: :convergence_hold,
      hold_id: @hold_id,
      head_sha: @head_2,
      reason: :repeated_cluster,
      cluster_ids: [@cluster_b]
    }

    bodies = Enum.map([intent_2, hold, completed_1, intent_1], &encoded_comment/1)

    assert {:ok, history} = ReviewConvergenceLedger.history(bodies)
    assert history.rework_count == 1
    assert history.last_completed_rework == completed_1
    assert history.completed_cluster_ids_by_head == %{@head_1 => MapSet.new([@cluster_a])}
    assert history.pending_transitions == %{@operation_2 => intent_2}
    assert history.holds_by_head == %{@head_2 => hold}
  end

  test "completion without a matching intent and contradictory manifests fail closed" do
    completion = event(:rework_completed, @operation_1, 1, @head_1, [@cluster_a])

    assert {:error, :completion_without_intent} =
             ReviewConvergenceLedger.history([encoded_comment(completion)])

    intent = event(:rework_intent, @operation_1, 1, @head_1, [@cluster_a])
    conflicting = event(:rework_completed, @operation_1, 1, @head_1, [@cluster_b])

    assert {:error, :completion_manifest_mismatch} =
             ReviewConvergenceLedger.history([encoded_comment(intent), encoded_comment(conflicting)])

    other_intent = event(:rework_intent, @operation_2, 1, @head_2, [@cluster_b])

    assert {:error, :duplicate_rework_round} =
             ReviewConvergenceLedger.history([encoded_comment(intent), encoded_comment(other_intent)])
  end

  test "history treats identical events idempotently and rejects contradictory operation reuse" do
    intent = event(:rework_intent, @operation_1, 1, @head_1, [@cluster_a])
    identical = encoded_comment(intent)

    assert {:ok, %{pending_transitions: %{@operation_1 => ^intent}}} =
             ReviewConvergenceLedger.history([identical, identical])

    contradiction = event(:rework_intent, @operation_1, 1, @head_2, [@cluster_a])

    assert {:error, :contradictory_operation} =
             ReviewConvergenceLedger.history([
               encoded_comment(intent),
               encoded_comment(contradiction)
             ])
  end

  test "history unions completed cluster manifests that share one head" do
    intent_1 = event(:rework_intent, @operation_1, 1, @head_1, [@cluster_a])
    completed_1 = %{intent_1 | kind: :rework_completed}
    intent_2 = event(:rework_intent, @operation_2, 2, @head_1, [@cluster_b])
    completed_2 = %{intent_2 | kind: :rework_completed}

    comments =
      Enum.map([intent_1, completed_1, intent_2, completed_2], &encoded_comment/1)

    assert {:ok, %{completed_cluster_ids_by_head: completed_by_head}} =
             ReviewConvergenceLedger.history(comments)

    assert completed_by_head == %{@head_1 => MapSet.new([@cluster_a, @cluster_b])}
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

  defp ledger_json(json) do
    "<!-- symphony-review-convergence-ledger:v1\n#{json}\n-->"
  end
end
