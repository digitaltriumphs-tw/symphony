defmodule SymphonyElixir.MergeAuthorizationTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubReviewClient
  alias SymphonyElixir.Linear.{Adapter, Issue}
  alias SymphonyElixir.{MergeAuthorization, MergeAuthorizationLedger, MergeExecutor}
  alias SymphonyElixir.ReviewMonitor

  @repository "aroakpm-svg/repo"
  @issue_id "issue-merge"
  @head_sha String.duplicate("a", 40)
  @base_sha String.duplicate("b", 40)
  @merge_sha String.duplicate("c", 40)

  defmodule ReviewClient do
    @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def snapshot(_repository, _branch), do: Application.fetch_env!(:symphony_elixir, :merge_snapshot)

    @spec request_review(String.t(), pos_integer(), String.t()) :: :ok
    def request_review(_repository, _number, _key), do: :ok

    @spec review_request_exists?(String.t(), pos_integer(), String.t()) :: {:ok, boolean()}
    def review_request_exists?(_repository, _number, _key), do: {:ok, false}

    @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok
    def publish_status(repository, head_sha, state, description, _target_url) do
      message = {:status, repository, head_sha, state, description}
      send(Application.fetch_env!(:symphony_elixir, :merge_recipient), message)
      :ok
    end

    @spec ruleset_receipt(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def ruleset_receipt(_repository, _base_ref) do
      Application.get_env(
        :symphony_elixir,
        :ruleset_result,
        {:ok, Application.fetch_env!(:symphony_elixir, :ruleset_receipt)}
      )
    end

    @spec pull_request_state(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
    def pull_request_state(_repository, _number),
      do: Application.fetch_env!(:symphony_elixir, :pull_request_state)

    @spec merge_pull_request(String.t(), pos_integer(), String.t(), String.t()) ::
            {:ok, map()} | {:error, term()}
    def merge_pull_request(repository, number, head_sha, method) do
      send(
        Application.fetch_env!(:symphony_elixir, :merge_recipient),
        {:merge, repository, number, head_sha, method}
      )

      Application.fetch_env!(:symphony_elixir, :merge_result)
    end
  end

  defmodule Tracker do
    @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_routed_issues_by_states(_states),
      do: {:ok, Application.fetch_env!(:symphony_elixir, :merge_issues)}

    @spec review_history(String.t()) :: {:ok, map()}
    def review_history(_issue_id),
      do: {:ok, Application.fetch_env!(:symphony_elixir, :merge_history)}

    @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :merge_recipient), {:comment, issue_id, body})

      failed_event =
        Application.get_env(:symphony_elixir, :fail_merge_event) ||
          if(Application.get_env(:symphony_elixir, :fail_merge_completion, false),
            do: :merge_completed
          )

      if is_atom(failed_event) and String.contains?(body, ~s("event":"#{failed_event}")) do
        {:error, :linear_unavailable}
      else
        :ok
      end
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :merge_recipient), {:state, issue_id, state})
      :ok
    end

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issue_states_by_ids(_issue_ids),
      do: {:ok, Application.fetch_env!(:symphony_elixir, :merge_issues)}
  end

  defmodule HistoryClient do
    @spec graphql(String.t(), map()) :: {:ok, map()}
    def graphql(_query, _variables) do
      {:ok, Application.fetch_env!(:symphony_elixir, :merge_history_page)}
    end
  end

  defmodule SequencedReleaseLookup do
    @moduledoc false
    @behaviour Access

    defstruct [:lookup_key, :value]

    @impl Access
    def fetch(%__MODULE__{lookup_key: key, value: value}, key) do
      counter_key = {__MODULE__, key}
      reads = Process.get(counter_key, 0)
      Process.put(counter_key, reads + 1)

      if reads < 2, do: {:ok, value}, else: :error
    end

    def fetch(%__MODULE__{}, _key), do: :error

    @impl Access
    def get_and_update(_lookup, _key, _function), do: raise("read-only test fixture")

    @impl Access
    def pop(_lookup, _key), do: raise("read-only test fixture")
  end

  setup do
    Application.put_env(:symphony_elixir, :merge_recipient, self())
    Application.put_env(:symphony_elixir, :merge_issues, [issue()])
    Application.put_env(:symphony_elixir, :merge_snapshot, {:ok, snapshot()})
    Application.put_env(:symphony_elixir, :ruleset_receipt, verified_ruleset_receipt())
    Application.put_env(:symphony_elixir, :pull_request_state, {:ok, open_pull_request()})
    Application.put_env(:symphony_elixir, :merge_result, {:ok, %{merged: true, merge_sha: @merge_sha}})
    Application.put_env(:symphony_elixir, :merge_history, empty_history())

    on_exit(fn ->
      for key <- [
            :merge_recipient,
            :merge_issues,
            :merge_snapshot,
            :ruleset_receipt,
            :pull_request_state,
            :merge_result,
            :merge_history,
            :merge_history_page,
            :fail_merge_completion,
            :fail_merge_event,
            :ruleset_result,
            :linear_client_module
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)
  end

  test "merge authorization is disabled by default and rejects unsafe methods" do
    assert {:ok, config} = Schema.parse(%{})
    refute config.merge_authorization.enabled
    assert config.merge_authorization.method == "squash"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "review_convergence" => %{"enabled" => true, "repository" => @repository},
               "merge_authorization" => %{"enabled" => true, "method" => "force"}
             })

    assert message =~ "merge_authorization.method"
  end

  test "pure policy blocks disabled, unreleased, mismatched, and held heads" do
    input = authorization_input()
    assert %{status: :holding, reason: :disabled} = MergeAuthorization.evaluate(put_in(input.settings.enabled, false))
    assert %{status: :holding, reason: :release_unverified} = MergeAuthorization.evaluate(input)

    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    mismatched_release = %{release_event(operation_id) | head_sha: String.duplicate("d", 40)}

    assert %{status: :holding, reason: :release_unverified} =
             input
             |> put_in([:merge_history, :releases], %{operation_id => mismatched_release})
             |> MergeAuthorization.evaluate()

    held = put_in(input.convergence_history.holds_by_head, %{@head_sha => %{hold_id: "hold"}})
    assert %{status: :holding, reason: :convergence_hold} = MergeAuthorization.evaluate(held)
  end

  test "pure policy requires verified strict ruleset evidence and returns merge ready only for an exact release" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())

    released =
      authorization_input()
      |> put_in([:merge_history, :releases], %{operation_id => release_event(operation_id)})

    for receipt <- [
          %{verified_ruleset_receipt() | status: :unverified},
          %{verified_ruleset_receipt() | strict: false},
          %{verified_ruleset_receipt() | required_context: nil}
        ] do
      assert %{status: :ruleset_unverified} =
               released
               |> Map.put(:ruleset_receipt, receipt)
               |> MergeAuthorization.evaluate()
    end

    assert %{
             status: :merge_ready,
             operation_id: ^operation_id,
             repository: @repository,
             pull_request_number: 42,
             base_sha: @base_sha,
             head_sha: @head_sha
           } = MergeAuthorization.evaluate(released)
  end

  test "ruleset receipt accepts only explicit gate plus strict evidence from effective rules or classic protection" do
    rules = [
      %{
        "type" => "required_status_checks",
        "parameters" => %{
          "strict_required_status_checks_policy" => true,
          "required_status_checks" => [%{"context" => "Review Convergence Gate"}]
        }
      }
    ]

    assert %{status: :verified, source: :ruleset, strict: true} =
             GitHubReviewClient.normalize_ruleset_receipt_for_test(
               @repository,
               "main",
               {:ok, rules},
               {:ok, nil}
             )

    classic = %{
      "strict" => true,
      "checks" => [%{"context" => "Review Convergence Gate", "app_id" => 15_368}]
    }

    non_strict_rules =
      put_in(rules, [Access.at(0), "parameters", "strict_required_status_checks_policy"], false)

    assert %{status: :verified, source: :classic, strict: true} =
             GitHubReviewClient.normalize_ruleset_receipt_for_test(
               @repository,
               "main",
               {:ok, []},
               {:ok, classic}
             )

    for {rules_result, classic_result} <- [
          {{:error, {:command_failed, 1, "HTTP 403"}}, {:ok, classic}},
          {{:error, {:command_failed, 1, "HTTP 404"}}, {:ok, classic}},
          {{:ok, [%{"type" => "required_status_checks", "parameters" => %{}}]}, {:ok, classic}},
          {{:ok, non_strict_rules}, {:ok, classic}},
          {{:ok, []}, {:ok, %{classic | "strict" => false}}},
          {{:ok, []}, {:ok, %{"strict" => true, "checks" => []}}}
        ] do
      assert %{status: :unverified} =
               GitHubReviewClient.normalize_ruleset_receipt_for_test(
                 @repository,
                 "main",
                 rules_result,
                 classic_result
               )
    end
  end

  test "GitHub merge response and PR state normalizers preserve typed CAS failures" do
    assert {:ok, %{merged: true, merge_sha: @merge_sha}} =
             GitHubReviewClient.normalize_merge_response_for_test(
               Jason.encode!(%{"merged" => true, "sha" => @merge_sha}),
               0
             )

    assert {:error, :head_moved} =
             GitHubReviewClient.normalize_merge_response_for_test("gh: Conflict (HTTP 409)", 1)

    assert {:error, :permission_denied} =
             GitHubReviewClient.normalize_merge_response_for_test("gh: Forbidden (HTTP 403)", 1)

    assert {:error, :rate_limited} =
             GitHubReviewClient.normalize_merge_response_for_test(
               "gh: API rate limit exceeded (HTTP 403)",
               1
             )

    assert {:ok, %{status: :open, base_sha: @base_sha, head_sha: @head_sha}} =
             GitHubReviewClient.normalize_pull_request_state_for_test(%{
               "state" => "open",
               "merged" => false,
               "base" => %{"ref" => "main", "sha" => @base_sha},
               "head" => %{"sha" => @head_sha}
             })
  end

  test "merge ledger binds release, intent, failure, and completion to one operation" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    release = release_event(operation_id)
    intent = intent_event(operation_id)
    completed = Map.merge(intent, %{kind: :merge_completed, merge_sha: @merge_sha})

    bodies =
      Enum.map([release, intent, completed], fn event ->
        assert {:ok, body} = MergeAuthorizationLedger.encode(event)
        assert {:ok, ^event} = MergeAuthorizationLedger.parse_comment(body)
        body
      end)

    assert {:ok, history} = MergeAuthorizationLedger.history(bodies)
    assert history.releases[operation_id] == release
    assert history.intents[operation_id] == intent
    assert history.completions[operation_id] == completed
    assert history.failures == %{}

    mismatched = %{completed | head_sha: String.duplicate("d", 40)}
    assert {:ok, body} = MergeAuthorizationLedger.encode(mismatched)
    assert {:error, :completion_manifest_mismatch} = MergeAuthorizationLedger.history([hd(bodies), Enum.at(bodies, 1), body])
  end

  test "default-disabled convergence sends zero merge requests" do
    state = ReviewMonitor.run_with(%{}, settings(false), ReviewClient, Tracker)

    assert state[@issue_id].merge.status == :holding
    refute_receive {:merge, _, _, _, _}
    refute_receive {:state, _, _}
  end

  test "fully authorized exact head sends one merge and repeated polls never send twice" do
    state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)

    assert_receive {:merge, @repository, 42, @head_sha, "squash"}
    assert state[@issue_id].merge.status == :merged
    refute_receive {:state, _, _}

    state = ReviewMonitor.run_with(state, settings(true), ReviewClient, Tracker)
    assert state[@issue_id].merge.status == :merged
    refute_receive {:merge, _, _, _, _}
  end

  test "unverified rulesets and head movement never call merge" do
    Application.put_env(:symphony_elixir, :ruleset_receipt, %{verified_ruleset_receipt() | status: :unverified})
    state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert state[@issue_id].merge.status == :ruleset_unverified
    refute_receive {:merge, _, _, _, _}

    Application.put_env(:symphony_elixir, :ruleset_receipt, verified_ruleset_receipt())

    Application.put_env(
      :symphony_elixir,
      :pull_request_state,
      {:ok, %{open_pull_request() | head_sha: String.duplicate("d", 40)}}
    )

    moved = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert moved[@issue_id].merge.status == :merge_failed
    assert moved[@issue_id].merge.failure == :head_moved
    refute_receive {:merge, _, _, _, _}
    refute_receive {:state, _, _}
  end

  test "GitHub failure stays In Review with typed merge_failed state and no success receipt" do
    Application.put_env(:symphony_elixir, :merge_result, {:error, :permission_denied})

    state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert_receive {:merge, @repository, 42, @head_sha, "squash"}
    assert state[@issue_id].merge.status == :merge_failed
    assert state[@issue_id].merge.failure == :permission_denied
    refute_receive {:state, _, _}

    refute Enum.any?(state[@issue_id].merge.receipts, fn event ->
             event.kind == :merge_completed
           end)
  end

  test "a terminal cache applies only to the exact base and head operation" do
    Application.put_env(:symphony_elixir, :merge_result, {:error, :permission_denied})

    first = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    first_operation_id = first[@issue_id].merge.operation_id

    assert_receive {:merge, @repository, 42, @head_sha, "squash"}
    assert first[@issue_id].merge.status == :merge_failed

    new_base_sha = String.duplicate("d", 40)
    new_snapshot = %{snapshot() | base_ref_oid: new_base_sha}

    Application.put_env(:symphony_elixir, :merge_snapshot, {:ok, new_snapshot})
    Application.put_env(:symphony_elixir, :pull_request_state, {:ok, %{open_pull_request() | base_sha: new_base_sha}})
    Application.put_env(:symphony_elixir, :merge_result, {:ok, %{merged: true, merge_sha: @merge_sha}})

    second = ReviewMonitor.run_with(first, settings(true), ReviewClient, Tracker)
    expected_operation_id = MergeAuthorization.operation_id(@issue_id, new_snapshot)

    assert_receive {:merge, @repository, 42, @head_sha, "squash"}
    assert second[@issue_id].merge.status == :merged
    assert second[@issue_id].merge.base_sha == new_base_sha
    assert second[@issue_id].merge.operation_id == expected_operation_id
    refute second[@issue_id].merge.operation_id == first_operation_id
    refute_receive {:state, _, _}
  end

  test "restart recovers an already-merged intent without a second merge request" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())

    Application.put_env(
      :symphony_elixir,
      :merge_history,
      empty_history(%{
        merge: %{
          releases: %{operation_id => release_event(operation_id)},
          intents: %{operation_id => intent_event(operation_id)},
          completions: %{},
          failures: %{},
          ledger_error: nil
        }
      })
    )

    Application.put_env(:symphony_elixir, :merge_snapshot, {:error, :pull_request_not_found})

    Application.put_env(
      :symphony_elixir,
      :pull_request_state,
      {:ok, %{open_pull_request() | status: :merged, merged: true, merge_sha: @merge_sha}}
    )

    state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert state[@issue_id].merge.status == :merged
    refute_receive {:merge, _, _, _, _}
    assert_receive {:comment, @issue_id, completion}
    assert completion =~ ~s("event":"merge_completed")
    refute_receive {:state, _, _}
  end

  test "restart with an open exact intent persists unknown outcome and never merges again" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())

    Application.put_env(
      :symphony_elixir,
      :merge_history,
      empty_history(%{
        merge: %{
          releases: %{operation_id => release_event(operation_id)},
          intents: %{operation_id => intent_event(operation_id)},
          completions: %{},
          failures: %{},
          ledger_error: nil
        }
      })
    )

    state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)

    assert state[@issue_id].merge.status == :merge_failed
    assert state[@issue_id].merge.failure == :merge_outcome_unknown
    refute_receive {:merge, _, _, _, _}
    assert_receive {:comment, @issue_id, failure_body}

    assert {:ok, %{kind: :merge_failed, failure: :merge_outcome_unknown}} =
             MergeAuthorizationLedger.parse_comment(failure_body)

    refute_receive {:state, _, _}
  end

  test "a merged GitHub response with failed completion persistence retries only the receipt" do
    Application.put_env(:symphony_elixir, :fail_merge_completion, true)
    first = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert_receive {:merge, @repository, 42, @head_sha, "squash"}
    assert first[@issue_id].merge.status == :merged

    Application.put_env(:symphony_elixir, :fail_merge_completion, false)

    Application.put_env(
      :symphony_elixir,
      :pull_request_state,
      {:ok, %{open_pull_request() | status: :merged, merged: true, merge_sha: @merge_sha}}
    )

    second = ReviewMonitor.run_with(first, settings(true), ReviewClient, Tracker)
    assert second[@issue_id].merge.status == :merged
    refute_receive {:merge, _, _, _, _}
  end

  test "Linear review history restores durable merge authorization receipts" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())

    bodies =
      Enum.map([release_event(operation_id), intent_event(operation_id)], fn event ->
        {:ok, body} = MergeAuthorizationLedger.encode(event)
        %{"body" => body}
      end)

    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)

    Application.put_env(:symphony_elixir, :merge_history_page, %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => bodies,
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    })

    assert {:ok, history} = Adapter.review_history(@issue_id)
    assert history.merge.releases[operation_id].kind == :authorization_release
    assert history.merge.intents[operation_id].kind == :merge_intent
  end

  test "ledger rejects invalid public inputs and malformed envelopes" do
    assert {:error, :invalid_merge_event} = MergeAuthorizationLedger.encode(nil)
    assert {:error, :invalid_merge_event} = MergeAuthorizationLedger.encode(%{})
    assert :none = MergeAuthorizationLedger.parse_comment("ordinary comment")
    assert {:error, :malformed_merge_event} = MergeAuthorizationLedger.parse_comment(nil)
    assert {:error, :malformed_merge_event} = MergeAuthorizationLedger.history(:not_a_list)

    assert {:error, :malformed_merge_event} =
             MergeAuthorizationLedger.parse_comment("<!-- symphony-merge-authorization-ledger:v1\n{}")

    for json <- ["not-json", "[]"] do
      assert {:error, :malformed_merge_event} =
               json |> raw_ledger() |> MergeAuthorizationLedger.parse_comment()
    end

    for {payload, expected} <- [
          {%{"schema_version" => 2}, :unsupported_merge_ledger_version},
          {%{"schema_version" => 1}, :unknown_merge_event},
          {%{"unexpected" => true}, :malformed_merge_event}
        ] do
      assert {:error, ^expected} =
               payload |> Jason.encode!() |> raw_ledger() |> MergeAuthorizationLedger.parse_comment()
    end
  end

  test "ledger rejects duplicate JSON keys at every nesting level" do
    duplicate_top =
      ~s({"schema_version":1,"schema_version":1,"event":"authorization_release"})

    duplicate_nested = ~s({"items":[{"key":1,"key":2}]})

    for json <- [duplicate_top, duplicate_nested] do
      assert {:error, :duplicate_json_key} =
               json |> raw_ledger() |> MergeAuthorizationLedger.parse_comment()
    end

    assert {:error, :malformed_merge_event} =
             ~s({"items":[1,2]})
             |> raw_ledger()
             |> MergeAuthorizationLedger.parse_comment()
  end

  test "ledger rejects malformed wire methods, failures, and common bindings" do
    valid_common = wire_common("merge_intent")

    cases = [
      {Map.put(valid_common, "method", "force"), :invalid_merge_method},
      {valid_common |> Map.put("method", "squash") |> Map.put("repository", "invalid"), :invalid_repository},
      {wire_common("merge_completed") |> Map.merge(%{"method" => "force", "merge_sha" => @merge_sha}), :invalid_merge_method},
      {wire_common("merge_completed") |> Map.merge(%{"method" => "squash", "merge_sha" => "bad"}), :invalid_sha},
      {wire_common("merge_failed") |> Map.merge(%{"method" => "force", "failure" => "conflict"}), :invalid_merge_method},
      {wire_common("merge_failed") |> Map.merge(%{"method" => "squash", "failure" => "mystery"}), :invalid_merge_failure},
      {wire_common("merge_failed")
       |> Map.merge(%{"method" => "squash", "failure" => "conflict", "pull_request_number" => 0}), :invalid_pull_request_number}
    ]

    for {payload, expected} <- cases do
      assert {:error, ^expected} =
               payload |> Jason.encode!() |> raw_ledger() |> MergeAuthorizationLedger.parse_comment()
    end
  end

  test "ledger event encoding rejects invalid values without weakening its schema" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    intent = intent_event(operation_id)

    invalid_events = [
      %{release_event(operation_id) | pull_request_number: 0},
      intent |> Map.put(:kind, :merge_completed) |> Map.put(:merge_sha, "bad"),
      intent |> Map.put(:kind, :merge_failed) |> Map.put(:failure, :unknown_failure),
      %{intent | method: "force"},
      %{kind: :unknown},
      Map.put(release_event(operation_id), :extra, true)
    ]

    for event <- invalid_events do
      assert {:error, :invalid_merge_event} = MergeAuthorizationLedger.encode(event)
    end
  end

  test "ledger history rejects missing, duplicate, and contradictory transitions" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    release = release_event(operation_id)
    intent = intent_event(operation_id)
    completion = Map.merge(intent, %{kind: :merge_completed, merge_sha: @merge_sha})
    failure = Map.merge(intent, %{kind: :merge_failed, failure: :conflict})

    release_body = ledger_body(release)
    intent_body = ledger_body(intent)
    completion_body = ledger_body(completion)
    failure_body = ledger_body(failure)

    assert {:ok, %{releases: releases}} =
             MergeAuthorizationLedger.history(["ordinary", release_body, release_body])

    assert releases[operation_id] == release

    conflicting_release = %{release | head_sha: String.duplicate("d", 40)}

    assert {:error, :contradictory_merge_event} =
             MergeAuthorizationLedger.history([release_body, ledger_body(conflicting_release)])

    assert {:error, :malformed_merge_event} =
             MergeAuthorizationLedger.history(["<!-- symphony-merge-authorization-ledger:v1\n{"])

    assert {:error, :intent_without_release} = MergeAuthorizationLedger.history([intent_body])

    assert {:error, :intent_without_release} =
             MergeAuthorizationLedger.history([release_body, completion_body])

    assert {:ok, %{failures: failures}} =
             MergeAuthorizationLedger.history([release_body, intent_body, failure_body])

    assert failures[operation_id] == failure

    mismatched_failure = %{failure | method: "merge"}

    assert {:error, :failure_manifest_mismatch} =
             MergeAuthorizationLedger.history([
               release_body,
               intent_body,
               ledger_body(mismatched_failure)
             ])

    assert {:error, :contradictory_merge_outcome} =
             MergeAuthorizationLedger.history([
               release_body,
               intent_body,
               completion_body,
               failure_body
             ])
  end

  test "pure authorization projects terminal and malformed-history branches" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    release = release_event(operation_id)
    intent = intent_event(operation_id)
    completion = Map.merge(intent, %{kind: :merge_completed, merge_sha: @merge_sha})
    failure = Map.merge(intent, %{kind: :merge_failed, failure: :conflict})

    base =
      authorization_input()
      |> put_in([:merge_history, :releases], %{operation_id => release})
      |> put_in([:merge_history, :intents], %{operation_id => intent})

    assert %{status: :merge_ready, receipts: [^release, ^intent]} = MergeAuthorization.evaluate(base)

    assert %{status: :merged, receipts: [^release, ^intent, ^completion]} =
             base
             |> put_in([:merge_history, :completions], %{operation_id => completion})
             |> MergeAuthorization.evaluate()

    assert %{status: :merge_failed, failure: :conflict, receipts: [^release, ^intent, ^failure]} =
             base
             |> put_in([:merge_history, :failures], %{operation_id => failure})
             |> MergeAuthorization.evaluate()

    mismatched_intent = %{intent | method: "merge"}

    assert %{status: :holding, reason: :intent_unverified} =
             base
             |> put_in([:merge_history, :intents], %{operation_id => mismatched_intent})
             |> MergeAuthorization.evaluate()

    assert %{status: :holding, reason: :invalid_merge_ledger} =
             authorization_input()
             |> Map.put(:merge_history, nil)
             |> MergeAuthorization.evaluate()
  end

  test "executor surfaces release, intent, failure, and completion persistence outages" do
    cases = [
      {:authorization_release, {:ok, %{merged: true, merge_sha: @merge_sha}}, :holding, :release_persist_failed, :authorization_release, false},
      {:merge_intent, {:ok, %{merged: true, merge_sha: @merge_sha}}, :merge_ready, :intent_persist_failed, :merge_intent, false},
      {:merge_failed, {:error, :permission_denied}, :merge_failed, :failure_persist_failed, :merge_failed, true},
      {:merge_completed, {:ok, %{merged: true, merge_sha: @merge_sha}}, :merged, :completion_persist_failed, :merge_completed, true}
    ]

    for {failed_event, merge_result, status, reason, pending_kind, merge_called?} <- cases do
      Application.put_env(:symphony_elixir, :fail_merge_event, failed_event)
      Application.put_env(:symphony_elixir, :merge_result, merge_result)

      state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
      merge = state[@issue_id].merge

      assert merge.status == status
      assert merge.reason == reason
      assert merge.pending_receipt.kind == pending_kind

      if merge_called? do
        assert_received {:merge, @repository, 42, @head_sha, "squash"}
      else
        refute_received {:merge, _, _, _, _}
      end

      flush_messages()
    end
  end

  test "executor recovery classifies every non-completion PR state without merging" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    pending_history = history_with_pending_intent(operation_id)

    cases = [
      {{:ok, %{open_pull_request() | base_sha: String.duplicate("d", 40)}}, :base_moved},
      {{:ok, %{open_pull_request() | head_sha: String.duplicate("d", 40)}}, :head_moved},
      {{:ok, %{open_pull_request() | status: :closed}}, :pull_request_closed},
      {{:error, :rate_limited}, :rate_limited}
    ]

    for {pull_request_state, failure} <- cases do
      Application.put_env(:symphony_elixir, :merge_history, pending_history)
      Application.put_env(:symphony_elixir, :pull_request_state, pull_request_state)

      state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)

      assert state[@issue_id].merge.status == :merge_failed
      assert state[@issue_id].merge.failure == failure
      refute_received {:merge, _, _, _, _}
      flush_messages()
    end
  end

  test "executor validates fresh PR state before any merge request" do
    cases = [
      {{:ok, %{open_pull_request() | base_sha: String.duplicate("d", 40)}}, :merge_failed, :base_moved},
      {{:ok, %{open_pull_request() | status: :merged, merged: true, merge_sha: @merge_sha}}, :merged, nil},
      {{:ok, %{open_pull_request() | status: :closed}}, :merge_failed, :pull_request_closed},
      {{:error, :unexpected_transport}, :merge_failed, :github_unavailable}
    ]

    for {pull_request_state, status, failure} <- cases do
      Application.put_env(:symphony_elixir, :merge_history, empty_history())
      Application.put_env(:symphony_elixir, :pull_request_state, pull_request_state)

      state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)

      assert state[@issue_id].merge.status == status
      assert state[@issue_id].merge.failure == failure
      refute_received {:merge, _, _, _, _}
      flush_messages()
    end
  end

  test "executor restores durable outcomes and normalizes missing history and settings" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    release = release_event(operation_id)
    intent = intent_event(operation_id)
    completion = Map.merge(intent, %{kind: :merge_completed, merge_sha: @merge_sha})
    failure = Map.merge(intent, %{kind: :merge_failed, failure: :conflict})

    for {field, event, status, expected_failure} <- [
          {:completions, completion, :merged, nil},
          {:failures, failure, :merge_failed, :conflict}
        ] do
      merge_history =
        empty_merge_history()
        |> put_in([:releases, operation_id], release)
        |> put_in([:intents, operation_id], intent)
        |> put_in([field, operation_id], event)

      restored = MergeExecutor.restore(%{}, %{merge: merge_history})
      assert restored.merge.status == status
      assert restored.merge.failure == expected_failure
    end

    assert MergeExecutor.pending_intent(%{merge: nil}) == nil
    assert %{reason: :disabled, method: "squash"} = MergeExecutor.default_state(%{})
  end

  test "executor fails closed on ruleset lookup, duplicate evidence, and missing prerequisites" do
    Application.put_env(:symphony_elixir, :ruleset_result, {:error, :forbidden})
    unverified = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert unverified[@issue_id].merge.status == :ruleset_unverified
    flush_messages()

    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())
    release = release_event(operation_id)

    Application.delete_env(:symphony_elixir, :ruleset_result)

    Application.put_env(
      :symphony_elixir,
      :merge_history,
      empty_history(%{merge: %{empty_merge_history() | releases: %{operation_id => release}}})
    )

    durable = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert durable[@issue_id].merge.status == :merged
    assert_received {:merge, @repository, 42, @head_sha, "squash"}
    flush_messages()

    contradictory_release = %{release | head_sha: String.duplicate("d", 40)}

    Application.put_env(
      :symphony_elixir,
      :merge_history,
      empty_history(%{
        merge: %{empty_merge_history() | releases: %{operation_id => contradictory_release}}
      })
    )

    contradictory = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert contradictory[@issue_id].merge.reason == :release_persist_failed
    flush_messages()

    dedup_key = "merge-ledger:authorization_release:#{operation_id}"
    Application.put_env(:symphony_elixir, :merge_history, empty_history(%{dedup: MapSet.new([dedup_key])}))

    deduplicated = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)
    assert deduplicated[@issue_id].merge.reason == :release_persist_failed
    flush_messages()

    pending_completion = Map.merge(intent_event(operation_id), %{kind: :merge_completed, merge_sha: @merge_sha})

    entry = %{
      dedup: MapSet.new(),
      convergence_history: %{merge: empty_merge_history()},
      merge:
        struct(MergeAuthorization.State,
          status: :merged,
          pending_receipt: pending_completion,
          receipts: [%{unrecognized: true}]
        )
    }

    assert MergeExecutor.reconcile(issue(), entry, settings(true), ReviewClient, Tracker, snapshot()) == entry
  end

  test "executor fails closed when release evidence disappears before intent persistence" do
    operation_id = MergeAuthorization.operation_id(@issue_id, snapshot())

    releases = %SequencedReleaseLookup{
      lookup_key: operation_id,
      value: release_event(operation_id)
    }

    Application.put_env(
      :symphony_elixir,
      :merge_history,
      empty_history(%{merge: %{empty_merge_history() | releases: releases}})
    )

    state = ReviewMonitor.run_with(%{}, settings(true), ReviewClient, Tracker)

    assert state[@issue_id].merge.status == :merge_ready
    assert state[@issue_id].merge.reason == :intent_persist_failed
    assert state[@issue_id].merge.pending_receipt.kind == :merge_intent
    refute_received {:merge, _, _, _, _}
  end

  defp raw_ledger(json),
    do: "<!-- symphony-merge-authorization-ledger:v1\n#{json}\n-->"

  defp wire_common(event) do
    %{
      "schema_version" => 1,
      "event" => event,
      "operation_id" => MergeAuthorization.operation_id(@issue_id, snapshot()),
      "repository" => @repository,
      "pull_request_number" => 42,
      "base_sha" => @base_sha,
      "head_sha" => @head_sha
    }
  end

  defp ledger_body(event) do
    {:ok, body} = MergeAuthorizationLedger.encode(event)
    body
  end

  defp history_with_pending_intent(operation_id) do
    empty_history(%{
      merge: %{
        empty_merge_history()
        | releases: %{operation_id => release_event(operation_id)},
          intents: %{operation_id => intent_event(operation_id)}
      }
    })
  end

  defp empty_merge_history do
    %{releases: %{}, intents: %{}, completions: %{}, failures: %{}, ledger_error: nil}
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp settings(enabled) do
    %{
      enabled: true,
      repository: @repository,
      review_state: "In Review",
      in_progress_state: "In Progress",
      max_fix_rounds: 3,
      human_owner: "owner",
      merge_authorization: %{enabled: enabled, method: "squash"}
    }
  end

  defp authorization_input do
    %{
      settings: %{enabled: true, method: "squash"},
      issue_id: @issue_id,
      snapshot: snapshot(),
      convergence_history: %{holds_by_head: %{}},
      merge_history: %{
        releases: %{},
        intents: %{},
        completions: %{},
        failures: %{},
        ledger_error: nil
      },
      ruleset_receipt: verified_ruleset_receipt()
    }
  end

  defp empty_history(overrides \\ %{}) do
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
        last_head_sha: nil,
        merge: %{
          releases: %{},
          intents: %{},
          completions: %{},
          failures: %{},
          ledger_error: nil
        }
      },
      overrides
    )
  end

  defp snapshot do
    %{
      repository: @repository,
      pull_request_number: 42,
      current_head_sha: @head_sha,
      reviewed_head_sha: @head_sha,
      review_result: :no_major_issues,
      base_ref_name: "main",
      base_ref_oid: @base_sha,
      base_verification_required: false,
      base_verification: :not_required,
      scope_contract: {:ok, nil},
      required_checks: [%{name: "test", state: :success}],
      threads: [],
      waiting_reason: nil
    }
  end

  defp issue do
    %Issue{
      id: @issue_id,
      identifier: "ARO-200",
      title: "Authorized merge",
      state: "In Review",
      branch_name: "codex/aro-200",
      url: "https://linear.test/ARO-200",
      labels: []
    }
  end

  defp verified_ruleset_receipt do
    %{
      status: :verified,
      repository: @repository,
      base_ref: "main",
      source: :ruleset,
      required_context: "Review Convergence Gate",
      strict: true
    }
  end

  defp open_pull_request do
    %{
      status: :open,
      merged: false,
      base_ref: "main",
      base_sha: @base_sha,
      head_sha: @head_sha,
      merge_sha: nil
    }
  end

  defp release_event(operation_id) do
    %{
      kind: :authorization_release,
      operation_id: operation_id,
      repository: @repository,
      pull_request_number: 42,
      base_sha: @base_sha,
      head_sha: @head_sha
    }
  end

  defp intent_event(operation_id) do
    release_event(operation_id)
    |> Map.put(:kind, :merge_intent)
    |> Map.put(:method, "squash")
  end
end
