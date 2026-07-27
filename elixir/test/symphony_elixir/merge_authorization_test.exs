defmodule SymphonyElixir.MergeAuthorizationTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubReviewClient
  alias SymphonyElixir.Linear.{Adapter, Issue}
  alias SymphonyElixir.MergeAuthorization
  alias SymphonyElixir.MergeAuthorizationLedger
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

    @spec ruleset_receipt(String.t(), String.t()) :: {:ok, map()}
    def ruleset_receipt(_repository, _base_ref) do
      {:ok, Application.fetch_env!(:symphony_elixir, :ruleset_receipt)}
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

      if Application.get_env(:symphony_elixir, :fail_merge_completion, false) and
           String.contains?(body, ~s("event":"merge_completed")) do
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
