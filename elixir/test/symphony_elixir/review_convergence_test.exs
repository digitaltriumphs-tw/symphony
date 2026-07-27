defmodule SymphonyElixir.ReviewConvergenceTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubReviewClient
  alias SymphonyElixir.Linear.{Adapter, Issue}
  alias SymphonyElixir.ReviewConvergence
  alias SymphonyElixir.ReviewConvergenceLedger
  alias SymphonyElixir.ReviewMonitor
  alias SymphonyElixir.ScopeContract

  @cluster_ac_1 "symphony-review-finding-cluster:v1:992112030cba4e48b120c7f3add9d5af9a895d323af521366122dc2f824bec84"
  @cluster_current_diff "symphony-review-finding-cluster:v1:506b3e7fedceec635a36c148ae36dfa839a445ffda1a32ecc3cc4f86a81189ba"
  @head_sha String.duplicate("a", 40)
  @new_head_sha String.duplicate("b", 40)
  @operation_head_a "b2b2a24890c798fe7362f0266f77dd41494e22058102bbfdab5ba4202aa305f1"
  @operation_head_b "91218d50cfee8c4dd0bc8a3df81a23d86e587a197c2a20e649429e048d327d9e"
  @operation_head_c "a3ff0bf1419c11b04f71a7f8e6a9a55ff5839dc10fd2869303a6eedd35e3a1f8"
  @forged_operation String.duplicate("f", 64)
  @pending_operation String.duplicate("4", 64)
  @completed_operation String.duplicate("5", 64)
  @conflicting_operation String.duplicate("6", 64)
  @hold_id String.duplicate("d", 64)

  defmodule ReviewClient do
    @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def snapshot(_repository, _branch), do: Application.fetch_env!(:symphony_elixir, :review_snapshot)

    @spec request_review(String.t(), pos_integer(), String.t()) :: :ok
    def request_review(repository, number, key) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:review_requested, repository, number, key})
      :ok
    end

    @spec review_request_exists?(String.t(), pos_integer(), String.t()) :: {:ok, boolean()}
    def review_request_exists?(_repository, _number, key) do
      {:ok, key in Application.get_env(:symphony_elixir, :existing_review_keys, [])}
    end

    @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok
    def publish_status(repository, head_sha, state, description, _target_url) do
      send(
        Application.fetch_env!(:symphony_elixir, :review_recipient),
        {:status, repository, head_sha, state, description}
      )

      :ok
    end
  end

  defmodule Tracker do
    @spec fetch_routed_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_routed_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states), do: {:ok, Application.fetch_env!(:symphony_elixir, :review_issues)}

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
    def fetch_issue_states_by_ids([issue_id]) do
      case Application.get_env(:symphony_elixir, :verified_issue_state, "In Progress") do
        {:error, reason} ->
          {:error, reason}

        state ->
          issue = Application.fetch_env!(:symphony_elixir, :review_issues) |> hd()
          {:ok, [%{issue | id: issue_id, state: state}]}
      end
    end

    @spec review_history(String.t()) :: {:ok, map()} | {:error, term()}
    def review_history(_issue_id),
      do: Application.get_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new(), rework_count: 0}})

    @spec create_comment(String.t(), String.t()) :: :ok
    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:comment, issue_id, body})
      :ok
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:state, issue_id, state})
      Application.get_env(:symphony_elixir, :review_state_result, :ok)
    end
  end

  defmodule FailingIssueTracker do
    @spec fetch_routed_issues_by_states([String.t()]) :: {:error, :linear_unavailable}
    def fetch_routed_issues_by_states(_states), do: {:error, :linear_unavailable}
  end

  setup do
    Application.put_env(:symphony_elixir, :review_recipient, self())
    Application.put_env(:symphony_elixir, :review_issues, [issue()])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :review_recipient)
      Application.delete_env(:symphony_elixir, :review_issues)
      Application.delete_env(:symphony_elixir, :review_snapshot)
      Application.delete_env(:symphony_elixir, :existing_review_keys)
      Application.delete_env(:symphony_elixir, :review_history)
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :review_state_result)
      Application.delete_env(:symphony_elixir, :verified_issue_state)
    end)
  end

  test "review convergence config is disabled by default and fail-closed when enabled without a repository" do
    assert {:ok, config} = Schema.parse(%{})
    refute config.review_convergence.enabled

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"review_convergence" => %{"enabled" => true}})

    assert message =~ "review_convergence.repository"

    assert {:error, {:invalid_workflow_config, malformed_message}} =
             Schema.parse(%{
               "review_convergence" => %{"enabled" => true, "repository" => "symphony"}
             })

    assert malformed_message =~ "must use owner/name format"
  end

  test "missing expected GitHub Actions checks fail closed instead of treating zero rows as passing" do
    assert {:ok, checks} = GitHubReviewClient.normalize_expected_checks_for_test(%{"check_runs" => []})

    assert checks == [
             %{name: "make-all", state: :missing, link: nil},
             %{name: "validate-pr-description", state: :missing, link: nil}
           ]
  end

  test "expected checks require exact job and GitHub Actions app identities" do
    run = fn name, slug, id, conclusion ->
      %{
        "name" => name,
        "status" => "completed",
        "conclusion" => conclusion,
        "details_url" => "url/#{name}",
        "app" => %{"slug" => slug, "id" => id}
      }
    end

    payload = %{
      "check_runs" => [
        run.("make-all", "github-actions", 15_368, "success"),
        run.("validate-pr-description", "impostor", 15_368, "success"),
        run.("validate-pr-description", "github-actions", 15_368, "failure")
      ]
    }

    assert {:ok,
            [
              %{name: "make-all", state: :success},
              %{name: "validate-pr-description", state: :failure}
            ]} = GitHubReviewClient.normalize_expected_checks_for_test(payload)
  end

  test "check-run REST pages are all merged before expected checks are selected" do
    first = %{"check_runs" => [%{"name" => "unrelated"}]}

    second = %{
      "check_runs" => [
        %{
          "name" => "make-all",
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"slug" => "github-actions", "id" => 15_368}
        },
        %{
          "name" => "validate-pr-description",
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"slug" => "github-actions", "id" => 15_368}
        }
      ]
    }

    assert {:ok, payload} = GitHubReviewClient.merge_check_run_pages_for_test([first, second])

    assert {:ok, [%{state: :success}, %{state: :success}]} =
             GitHubReviewClient.normalize_expected_checks_for_test(payload)
  end

  test "GitHub skipped conclusion uses the explicitly allowed skipped gate state" do
    run = fn name ->
      %{
        "name" => name,
        "status" => "completed",
        "conclusion" => "skipped",
        "app" => %{"slug" => "github-actions", "id" => 15_368}
      }
    end

    assert {:ok, [%{state: :skipped}, %{state: :skipped}]} =
             GitHubReviewClient.normalize_expected_checks_for_test(%{
               "check_runs" => [run.("make-all"), run.("validate-pr-description")]
             })
  end

  test "formal pass requires the trusted reviewer database identity on the current head" do
    trusted = %{
      "body" => "No major issues found",
      "state" => "COMMENTED",
      "commit" => %{"oid" => "head"},
      "author" => %{
        "login" => "chatgpt-codex-connector",
        "__typename" => "Organization",
        "databaseId" => 261_883_814
      }
    }

    assert GitHubReviewClient.accepted_review_for_test?(trusted, "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(trusted, ["author", "databaseId"], 123), "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(trusted, ["commit", "oid"], "old"), "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "state" => "DISMISSED"}, "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "state" => "PENDING"}, "head")
    refute GitHubReviewClient.accepted_review_for_test?(%{trusted | "body" => "No major issues found"}, "other")

    bot = %{
      trusted
      | "author" => %{
          "login" => "chatgpt-codex-connector[bot]",
          "__typename" => "Bot",
          "databaseId" => 199_175_422
        }
    }

    assert GitHubReviewClient.accepted_review_for_test?(bot, "head")
    refute GitHubReviewClient.accepted_review_for_test?(put_in(bot, ["author", "databaseId"], 123), "head")

    issue_comment = %{
      "body" => "No major issues found\n\n**Reviewed commit:** `head`",
      "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot", "id" => 199_175_422}
    }

    refute GitHubReviewClient.accepted_review_for_test?(issue_comment, "head")
  end

  test "formal pass uses only the latest unambiguous trusted current-head review" do
    head = "head"

    clean = %{
      "body" => "No major issues found",
      "state" => "COMMENTED",
      "submittedAt" => "2026-07-22T01:00:00Z",
      "commit" => %{"oid" => head},
      "author" => %{
        "login" => "chatgpt-codex-connector",
        "__typename" => "Organization",
        "databaseId" => 261_883_814
      }
    }

    assert GitHubReviewClient.latest_accepted_review_for_test([clean], head) == clean

    conflicting = %{
      clean
      | "body" => "Changes required",
        "state" => "CHANGES_REQUESTED",
        "submittedAt" => "2026-07-22T01:01:00Z"
    }

    refute GitHubReviewClient.latest_accepted_review_for_test([clean, conflicting], head)
    refute GitHubReviewClient.latest_accepted_review_for_test([clean, Map.delete(conflicting, "submittedAt")], head)
  end

  test "trusted current-head clean comment attests only to its unique earlier request" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))

    assert GitHubReviewClient.accepted_comment_attestation_for_test([request, clean], head) == clean

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, %{clean | "created_at" => "2026-07-22T00:59:00Z"}],
             head
           )

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, clean_attestation_comment("bbbbbbbbbb")],
             head
           )
  end

  test "comment attestation rejects duplicate requests and invalidates on a new head" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))

    refute GitHubReviewClient.accepted_comment_attestation_for_test([request, request, clean], head)
    refute GitHubReviewClient.accepted_comment_attestation_for_test([request, clean], String.duplicate("b", 40))
  end

  test "comment attestation rejects multiple trusted responses after one request" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))
    later = %{clean | "created_at" => "2026-07-22T01:06:00Z"}

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, clean, later],
             head
           )
  end

  test "comment attestation rejects impersonation, general comments, and missing app identity" do
    head = String.duplicate("a", 40)
    request = review_request_comment(head)
    clean = clean_attestation_comment(String.slice(head, 0, 10))

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, put_in(clean, ["user", "id"], 123)],
             head
           )

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, Map.put(clean, "performed_via_github_app", nil)],
             head
           )

    refute GitHubReviewClient.accepted_comment_attestation_for_test(
             [request, %{clean | "body" => "Looks good to me\n\n**Reviewed commit:** `aaaaaaaaaa`"}],
             head
           )
  end

  test "pending required checks returned with gh exit status 8 remain pending evidence" do
    output = Jason.encode!([%{"name" => "ci", "bucket" => "pending", "state" => "PENDING", "link" => "url"}])

    assert {:ok, [%{name: "ci", state: :pending}]} =
             GitHubReviewClient.normalize_required_checks_for_test(output, 8)
  end

  test "protected required checks normalize the gh skipping bucket as skipped" do
    output = Jason.encode!([%{"name" => "optional", "bucket" => "skipping", "state" => "SKIPPED", "link" => "url"}])

    assert {:ok, [%{name: "optional", state: :skipped}]} =
             GitHubReviewClient.normalize_required_checks_for_test(output, 0)
  end

  test "protected required checks are merged with bootstrap checks and cannot be masked" do
    expected = [
      %{name: "make-all", state: :success, link: "expected"},
      %{name: "validate-pr-description", state: :success, link: nil}
    ]

    protected = [
      %{name: "security", state: :pending, link: "security"},
      %{name: "make-all", state: :failure, link: "protected"}
    ]

    assert GitHubReviewClient.merge_required_checks_for_test(expected, protected) == [
             %{name: "make-all", state: :failure, link: "expected"},
             %{name: "security", state: :pending, link: "security"},
             %{name: "validate-pr-description", state: :success, link: nil}
           ]
  end

  test "authoritative ruleset and branch-protection contexts retain app identity" do
    rules = [
      %{
        "type" => "required_status_checks",
        "parameters" => %{
          "required_status_checks" => [
            %{"context" => "linux", "integration_id" => 42},
            %{"context" => "Review Convergence Gate", "integration_id" => nil}
          ]
        }
      }
    ]

    protection = %{"checks" => [%{"context" => "lint", "app_id" => 7}]}

    assert {:ok, contexts} =
             GitHubReviewClient.normalize_required_contexts_for_test(rules, protection)

    assert contexts == [%{name: "lint", app_id: 7}, %{name: "linux", app_id: 42}]
  end

  test "branch-protection app_id minus one allows any check provider" do
    protection = %{"checks" => [%{"context" => "lint", "app_id" => -1}]}

    assert {:ok, [%{name: "lint", app_id: nil}]} =
             GitHubReviewClient.normalize_required_contexts_for_test([], protection)

    assert {:ok, [%{name: "lint", state: :success}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               [%{name: "lint", app_id: nil}],
               %{
                 "check_runs" => [
                   %{
                     "name" => "lint",
                     "status" => "completed",
                     "conclusion" => "success",
                     "app" => %{"id" => 99}
                   }
                 ]
               }
             )
  end

  test "disabled classic required checks are absence, not an evidence error" do
    assert {:ok, nil} =
             GitHubReviewClient.normalize_branch_protection_response_for_test(
               "gh: Required status checks are not enabled for this branch. (HTTP 404)",
               1
             )

    assert {:error, {:required_status_checks_failed, 1, _}} =
             GitHubReviewClient.normalize_branch_protection_response_for_test(
               "gh: resource unavailable (HTTP 404)",
               1
             )
  end

  test "required contexts absent from current-head evidence are synthesized as missing" do
    contexts = [%{name: "linux", app_id: 42}, %{name: "lint", app_id: nil}]

    payload = %{
      "check_runs" => [
        %{
          "name" => "linux",
          "status" => "completed",
          "conclusion" => "success",
          "details_url" => "wrong-app",
          "app" => %{"id" => 9}
        }
      ]
    }

    assert {:ok, checks} = GitHubReviewClient.match_required_contexts_for_test(contexts, payload)
    assert checks == [%{name: "linux", state: :missing, link: nil}, %{name: "lint", state: :missing, link: nil}]
  end

  test "partial and complete current-head required evidence preserve pending and success" do
    contexts = [%{name: "linux", app_id: 42}, %{name: "lint", app_id: nil}]

    pending = %{
      "name" => "linux",
      "status" => "in_progress",
      "details_url" => "linux",
      "app" => %{"id" => 42}
    }

    success = %{
      "name" => "lint",
      "status" => "completed",
      "conclusion" => "success",
      "details_url" => "lint",
      "app" => %{"id" => 7}
    }

    assert {:ok, [%{state: :pending}, %{state: :success}]} =
             GitHubReviewClient.match_required_contexts_for_test(contexts, %{
               "check_runs" => [pending, success]
             })

    assert {:ok, [%{state: :success}, %{state: :success}]} =
             GitHubReviewClient.match_required_contexts_for_test(contexts, %{
               "check_runs" => [
                 pending |> Map.put("status", "completed") |> Map.put("conclusion", "success"),
                 success
               ]
             })
  end

  test "a newer queued rerun keeps a required context pending" do
    contexts = [%{name: "linux", app_id: 42}]

    old_success = %{
      "name" => "linux",
      "status" => "completed",
      "conclusion" => "success",
      "completed_at" => "2026-07-22T01:05:00Z",
      "created_at" => "2026-07-22T01:00:00Z",
      "details_url" => "old",
      "app" => %{"id" => 42}
    }

    queued_rerun = %{
      "name" => "linux",
      "status" => "queued",
      "created_at" => "2026-07-22T01:06:00Z",
      "details_url" => "new",
      "app" => %{"id" => 42}
    }

    assert {:ok, [%{state: :pending, link: "new"}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               contexts,
               %{"check_runs" => [old_success, queued_rerun]}
             )
  end

  test "legacy required commit statuses are matched on the current head" do
    contexts = [%{name: "jenkins", app_id: nil}]
    statuses = [%{"context" => "jenkins", "state" => "success", "target_url" => "jenkins/url"}]

    assert {:ok, [%{name: "jenkins", state: :success, link: "jenkins/url"}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               contexts,
               %{"check_runs" => []},
               statuses
             )
  end

  test "app-bound required contexts cannot be satisfied by a legacy commit status" do
    contexts = [%{name: "ci", app_id: 42}]
    statuses = [%{"context" => "ci", "state" => "success", "target_url" => "impostor"}]

    assert {:ok, [%{name: "ci", state: :missing, link: nil}]} =
             GitHubReviewClient.match_required_contexts_for_test(
               contexts,
               %{"check_runs" => []},
               statuses
             )
  end

  test "unknown required-rule or check evidence fails closed" do
    assert {:error, _} = GitHubReviewClient.normalize_required_contexts_for_test(%{}, nil)
    assert {:error, _} = GitHubReviewClient.match_required_contexts_for_test([], %{})
  end

  test "review thread pagination merges every page before evaluation" do
    page = fn body, has_next_page, end_cursor ->
      %{
        "data" => %{
          "repository" => %{
            "pullRequest" => %{
              "reviewThreads" => %{
                "nodes" => [%{"comments" => %{"nodes" => [%{"body" => body}]}}],
                "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
              }
            }
          }
        }
      }
    end

    assert {:ok, pull_request} =
             GitHubReviewClient.merge_pull_request_pages_for_test([
               page.("P4 first", true, "next"),
               page.("P1 second", false, nil)
             ])

    assert Enum.map(
             pull_request["reviewThreads"]["nodes"],
             &get_in(&1, ["comments", "nodes", Access.at(0), "body"])
           ) == ["P4 first", "P1 second"]
  end

  test "every paginated pull-request page must have valid data and pagination evidence" do
    valid = %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "reviewThreads" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "next"}
            }
          }
        }
      }
    }

    for invalid <- [
          %{"errors" => [%{"message" => "rate limited"}]},
          %{"data" => %{"repository" => %{"pullRequest" => nil}}},
          %{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{}}}}},
          %{
            "data" => %{
              "repository" => %{
                "pullRequest" => %{
                  "reviewThreads" => %{
                    "nodes" => "not-a-list",
                    "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                  }
                }
              }
            }
          }
        ] do
      assert {:error, {:invalid_pull_request_page, ^invalid}} =
               GitHubReviewClient.merge_pull_request_pages_for_test([valid, invalid])
    end
  end

  test "base refs are encoded as one GitHub API path segment" do
    assert GitHubReviewClient.encode_path_segment_for_test("release/2026.07") ==
             "release%2F2026.07"

    assert GitHubReviewClient.encode_path_segment_for_test("release 100%/台灣") ==
             "release%20100%25%2F%E5%8F%B0%E7%81%A3"
  end

  test "pull-request pagination exposes only the outer review-thread cursor" do
    query = GitHubReviewClient.pull_request_query_for_test()

    assert length(Regex.scan(~r/pageInfo \{ hasNextPage endCursor \}/, query)) == 1
    assert Regex.match?(~r/pullRequest\(number: \$number\) \{\s+number\s+body/, query)
    assert query =~ "reviewThreads(first: 100, after: $endCursor)"
    assert query =~ "comments(first: 100)"
    assert Regex.match?(~r/nodes \{\s+id\s+body\s+path\s+url\s+commit \{ oid \}/, query)
    assert query =~ "author {"
    assert query =~ "databaseId"
  end

  test "review request gives Codex the exact v1 disposition contract without treating severity as ownership" do
    body = GitHubReviewClient.review_request_body_for_test("review-key")

    assert body =~ "@codex review"
    assert body =~ "Severity P1-P4 indicates actionability, not scope ownership."

    assert body =~ """
           <!-- symphony-finding-disposition:v1
           {"schema_version":1,"kind":"same_pr","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"scope_ref":{"type":"acceptance_criterion","id":"AC-1"}}
           -->
           """

    assert body =~
             ~s|{"schema_version":1,"kind":"introduced_by_pr","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"proof":{"type":"current_pr_diff"}}|

    assert body =~
             ~s|{"schema_version":1,"kind":"human_hold","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"}}|

    assert body =~ "dedup-key: `review-key`"
  end

  test "selected finding metadata is normalized from one exact GitHub comment node" do
    trusted_actor = %{
      "login" => "chatgpt-codex-connector[bot]",
      "__typename" => "Bot",
      "databaseId" => 199_175_422
    }

    disposition = """
    P2 exact finding
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"same_pr","binding":{"base_sha":"base","head_sha":"head","path":"lib/current.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-1"}}
    -->
    """

    thread = %{
      "id" => "thread-42",
      "isResolved" => false,
      "comments" => %{
        "nodes" => [
          %{
            "id" => "comment-42",
            "body" => disposition,
            "path" => "lib/current.ex",
            "url" => "https://example.test/comment-42",
            "commit" => %{"oid" => "head"},
            "author" => trusted_actor
          }
        ]
      }
    }

    assert [
             %{
               thread_id: "thread-42",
               finding_comment_id: "comment-42",
               disposition_actor: ^trusted_actor,
               disposition: {:decoded, %{"kind" => "same_pr"}},
               body: ^disposition,
               path: "lib/current.ex",
               url: "https://example.test/comment-42",
               commit_sha: "head",
               priority: 2
             }
           ] = GitHubReviewClient.normalize_threads_for_test([thread], "head")
  end

  test "finding normalization never borrows disposition or actor evidence from another comment" do
    trusted_body = """
    P2 older finding
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"same_pr","binding":{"base_sha":"base","head_sha":"old","path":"lib/old.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-1"}}
    -->
    """

    selected_actor = %{"login" => "human-reviewer", "__typename" => "User", "databaseId" => 77}

    thread = %{
      "id" => "thread-selected",
      "isResolved" => false,
      "comments" => %{
        "nodes" => [
          %{
            "id" => "comment-old",
            "body" => trusted_body,
            "path" => "lib/old.ex",
            "url" => "old-url",
            "commit" => %{"oid" => "old"},
            "author" => %{
              "login" => "chatgpt-codex-connector[bot]",
              "__typename" => "Bot",
              "databaseId" => 199_175_422
            }
          },
          %{
            "id" => "comment-selected",
            "body" => "P1 selected finding without metadata",
            "path" => "lib/selected.ex",
            "url" => "selected-url",
            "commit" => %{"oid" => "head"},
            "author" => selected_actor
          }
        ]
      }
    }

    assert [
             %{
               thread_id: "thread-selected",
               finding_comment_id: "comment-selected",
               disposition_actor: ^selected_actor,
               disposition: :missing,
               body: "P1 selected finding without metadata",
               path: "lib/selected.ex",
               url: "selected-url",
               commit_sha: "head"
             }
           ] = GitHubReviewClient.normalize_threads_for_test([thread], "head")
  end

  test "unresolved actionable threads remain blocking across head changes" do
    thread = fn commit, body ->
      %{
        "isResolved" => false,
        "comments" => %{
          "nodes" => [
            %{"body" => body, "path" => "lib/example.ex", "url" => "url", "commit" => %{"oid" => commit}}
          ]
        }
      }
    end

    assert [
             %{body: "P1 stale", commit_sha: "old"},
             %{body: "P2 current", commit_sha: "new"}
           ] =
             GitHubReviewClient.normalize_threads_for_test(
               [thread.("old", "P1 stale"), thread.("new", "P2 current")],
               "new"
             )
  end

  test "snapshot keeps unresolved actionable threads from prior heads" do
    pull_request = %{
      "body" => scope_contract_body(),
      "headRefOid" => "new",
      "baseRefOid" => "base",
      "reviews" => %{"nodes" => []},
      "reviewThreads" => %{
        "nodes" => [
          %{
            "isResolved" => false,
            "comments" => %{
              "nodes" => [
                %{
                  "body" => "P1 unresolved on prior head",
                  "path" => "lib/example.ex",
                  "url" => "thread",
                  "commit" => %{"oid" => "old"}
                }
              ]
            }
          }
        ]
      }
    }

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [%{name: "make-all", state: :success}],
        %{required: false, result: :verified},
        []
      )

    assert [%{body: "P1 unresolved on prior head", commit_sha: "old"}] = snapshot.threads
    assert {:ok, %ScopeContract{work_item: "Route verified review findings."}} = snapshot.scope_contract
    refute Map.has_key?(snapshot, :structural_risk)
  end

  test "a conflicting trusted formal review blocks comment-attestation fallback" do
    head = String.duplicate("d", 40)
    request = review_request_comment(head)
    clean_comment = clean_attestation_comment(head)

    pull_request = %{
      "headRefOid" => head,
      "baseRefOid" => "base",
      "reviewThreads" => %{"nodes" => []},
      "reviews" => %{
        "nodes" => [
          %{
            "commit" => %{"oid" => head},
            "state" => "CHANGES_REQUESTED",
            "body" => "P1 remains",
            "submittedAt" => "2026-07-22T01:10:00Z",
            "author" => %{
              "login" => "chatgpt-codex-connector[bot]",
              "__typename" => "Bot",
              "databaseId" => 199_175_422
            }
          }
        ]
      }
    }

    snapshot =
      GitHubReviewClient.normalize_snapshot_for_test(
        pull_request,
        [%{name: "make-all", state: :success}],
        %{required: false, result: :verified},
        [request, clean_comment]
      )

    assert snapshot.reviewed_head_sha == nil
    assert snapshot.review_result == :missing
  end

  test "a current-head follow-up on an older thread remains actionable" do
    thread = %{
      "isResolved" => false,
      "comments" => %{
        "nodes" => [
          %{"body" => "P4 old", "commit" => %{"oid" => "old"}},
          %{"body" => "P1 current follow-up", "path" => "lib/current.ex", "url" => "thread", "commit" => %{"oid" => "head"}}
        ]
      }
    }

    assert [%{body: "P1 current follow-up", priority: 1, commit_sha: "head"}] =
             GitHubReviewClient.normalize_threads_for_test([thread], "head")
  end

  test "old-head base-missing claims do not contaminate current-head follow-ups" do
    thread = %{
      "comments" => %{
        "nodes" => [
          %{
            "body" => "The base branch is missing `lib/old.ex`",
            "commit" => %{"oid" => "old"}
          },
          %{"body" => "Current-head follow-up", "commit" => %{"oid" => "head"}}
        ]
      }
    }

    assert GitHubReviewClient.base_missing_paths_for_test([thread], "head") == []

    current = put_in(thread, ["comments", "nodes", Access.at(1), "body"], "Base ref is missing `lib/current.ex`")
    assert GitHubReviewClient.base_missing_paths_for_test([current], "head") == ["lib/current.ex"]
  end

  test "review thread comments are merged across every comment page" do
    page = fn body ->
      %{"data" => %{"node" => %{"comments" => %{"nodes" => [%{"body" => body}]}}}}
    end

    assert {:ok, [%{"body" => "old"}, %{"body" => "current P1"}]} =
             GitHubReviewClient.merge_thread_comment_pages_for_test([
               page.("old"),
               page.("current P1")
             ])
  end

  test "a new head invalidates an old formal review and requests one deduplicated review" do
    snapshot = snapshot(%{current_head_sha: "new", reviewed_head_sha: "old"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, "aroakpm-svg/repo", "new", :pending, _}
    assert_receive {:review_requested, "aroakpm-svg/repo", 42, key}
    assert is_binary(key)

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "a persisted review-request key prevents a duplicate after monitor restart" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{reviewed_head_sha: nil})})
    digest = ReviewConvergence.dedup_key(:review_request, "issue-160", @head_sha, :codex)
    key = "review-request:issue-160:#{@head_sha}:#{digest}"
    Application.put_env(:symphony_elixir, :existing_review_keys, [key])

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:review_requested, _, _, _}
    assert_receive {:status, _, @head_sha, :pending, _}
  end

  defmodule HistoryClient do
    @spec graphql(String.t(), map()) :: {:ok, map()}
    def graphql(_query, variables) do
      send(Application.fetch_env!(:symphony_elixir, :review_recipient), {:history_page, variables.after})
      [response | rest] = Process.get(:history_responses)
      Process.put(:history_responses, rest)
      {:ok, response}
    end
  end

  test "review monitor ignores review-state issues outside tracker routing" do
    unroutable = %{issue() | id: "other", assigned_to_worker: false}
    Application.put_env(:symphony_elixir, :review_issues, [unroutable])
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{reviewed_head_sha: nil})})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:review_requested, _, _, _}
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "review monitor prunes entries for issues that left the review state" do
    Application.put_env(:symphony_elixir, :review_issues, [])

    stale_state = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "old-head",
        fetch_failed: false
      }
    }

    assert ReviewMonitor.run_with(stale_state, settings(), ReviewClient, Tracker) == %{}
    refute_receive {:status, _, _, _, _}
  end

  test "Linear history paginates, deduplicates keys, and quarantines legacy rework without a typed manifest" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)

    Process.put(:history_responses, [
      history_page([rework_body("one")], true, "next"),
      history_page([rework_body("one"), rework_body("two"), converged_body(String.duplicate("b", 40))], false, nil)
    ])

    assert {:ok,
            %{
              dedup: dedup,
              rework_count: 0,
              legacy_rework_count: 2,
              last_head_sha: last_head_sha
            }} =
             Adapter.review_history("issue-160")

    assert dedup == MapSet.new(["one", "two", "converged"])
    assert last_head_sha == String.duplicate("b", 40)
    assert_receive {:history_page, nil}
    assert_receive {:history_page, "next"}
  end

  test "Linear history restores typed completed manifests and only incomplete durable intents" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)
    head = String.duplicate("c", 40)

    Process.put(:history_responses, [
      history_page(
        [
          transition_intent_body(@pending_operation, head, 2, [@cluster_current_diff]),
          transition_intent_body(@completed_operation, head, 1, [@cluster_ac_1]),
          transition_completed_body(@completed_operation, head, 1, [@cluster_ac_1])
        ],
        false,
        nil
      )
    ])

    assert {:ok,
            %{
              pending_transitions: pending,
              rework_count: 1,
              last_completed_rework: completed,
              completed_cluster_ids_by_head: completed_by_head
            }} =
             Adapter.review_history("issue-160")

    assert pending == %{
             @pending_operation => %{
               kind: :rework_intent,
               operation_id: @pending_operation,
               round: 2,
               head_sha: head,
               target_state: "In Progress",
               cluster_ids: [@cluster_current_diff]
             }
           }

    assert completed == completed_rework(@completed_operation, 1, head, [@cluster_ac_1])
    assert completed_by_head == %{head => MapSet.new([@cluster_ac_1])}
  end

  test "malformed ledger history is returned as typed hold evidence instead of being interpreted by prose" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)

    Process.put(:history_responses, [
      history_page(
        [
          %{
            "body" =>
              "transition-operation: `intent`\ntransition-operation-id: `broken`\n" <>
                "<!-- symphony-review-convergence-ledger:v1\n{not-json}\n-->\n" <>
                "dedup-key: `transition-intent:broken`"
          }
        ],
        false,
        nil
      )
    ])

    assert {:ok, %{ledger_error: :malformed_ledger_event}} = Adapter.review_history("issue-160")
  end

  test "typed completion manifests must match their durable intent" do
    Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)
    intent_head = String.duplicate("d", 40)
    conflicting_head = String.duplicate("e", 40)

    Process.put(:history_responses, [
      history_page(
        [
          transition_intent_body(@conflicting_operation, intent_head, 1, [@cluster_ac_1]),
          transition_completed_body(@conflicting_operation, conflicting_head, 1, [@cluster_ac_1])
        ],
        false,
        nil
      )
    ])

    assert {:ok, %{ledger_error: :completion_manifest_mismatch}} =
             Adapter.review_history("issue-160")
  end

  test "structured snapshot errors fail closed without crashing comment rendering" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, {:command_failed, 8, %{state: :pending}}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "command_failed"
  end

  test "persisted wait key prevents duplicate evidence-outage effects after restart" do
    reason = inspect(:github_unavailable)
    key = ReviewConvergence.dedup_key(:wait, "issue-160", nil, reason)

    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})
    Application.put_env(:symphony_elixir, :review_history, {:ok, %{dedup: MapSet.new([key]), rework_count: 0}})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:comment, _, _}
  end

  test "evidence outage clears a known head's prior success with an error status" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: "known-head",
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, "known-head", :error, _}
    assert_receive {:comment, "issue-160", _}
  end

  test "restart restores persisted head before snapshot outage clears success" do
    persisted_head = String.duplicate("a", 40)
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: MapSet.new(), rework_count: 0, last_head_sha: persisted_head}}
    )

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, ^persisted_head, :error, _}
  end

  test "review-issue fetch outage clears each known head once until recovery" do
    entry = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: @head_sha,
        last_published_status: {@head_sha, :success},
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    state = ReviewMonitor.run_with(entry, settings(), ReviewClient, FailingIssueTracker)
    assert_receive {:status, _, @head_sha, :error, _}

    state = ReviewMonitor.run_with(state, settings(), ReviewClient, FailingIssueTracker)
    refute_receive {:status, _, _, _, _}

    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})
    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :success, _}
  end

  test "convergence republishes success after a transient error while keeping its comment deduplicated" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})
    key = ReviewConvergence.dedup_key(:converged, "issue-160", @head_sha, :technical)

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new([key]),
        fix_rounds: 0,
        head_sha: @head_sha,
        review_requested: false,
        waiting: true,
        last_finding_fingerprint: nil
      }
    }

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :success, _}
    refute_receive {:comment, _, _}
  end

  test "steady convergence does not republish the same head status every poll" do
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :success, _}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, @head_sha, :success, _}
  end

  test "previously deduplicated wait still replaces a later success when evidence regresses" do
    wait_key = ReviewConvergence.dedup_key(:wait, "issue-160", @head_sha, :required_checks_not_passed)

    entry = %{
      "issue-160" => %{
        dedup: MapSet.new([wait_key]),
        fix_rounds: 0,
        head_sha: @head_sha,
        last_published_status: {@head_sha, :success},
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      }
    }

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{required_checks: [%{name: "make-all", state: :pending}]})}
    )

    _state = ReviewMonitor.run_with(entry, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :pending, _}
    refute_receive {:comment, _, _}
  end

  test "review, required checks, and actionable threads are independent gates" do
    assert {:converged, _} = ReviewConvergence.evaluate(snapshot(), 0, 3)

    assert {:request_review, _} =
             snapshot(%{reviewed_head_sha: "old"}) |> ReviewConvergence.evaluate(0, 3)

    assert {:wait, %{reason: :required_checks_not_passed}} =
             snapshot(%{required_checks: [%{name: "test", state: :pending}]})
             |> ReviewConvergence.evaluate(0, 3)

    assert {:rework, %{same_pr_findings: [%{route: :same_pr}], held_findings: []}} =
             snapshot(%{threads: [same_pr_finding()]})
             |> ReviewConvergence.evaluate(0, 3)
  end

  test "an explicit human wait reason is preserved in the decision evidence" do
    assert {:wait, %{reason: :staging}} =
             snapshot(%{waiting_reason: :staging}) |> ReviewConvergence.evaluate(0, 3)
  end

  test "missing current head fails closed and malformed threads are not actionable" do
    assert {:wait, %{reason: :missing_current_head}} =
             snapshot(%{current_head_sha: nil, threads: [:malformed]})
             |> ReviewConvergence.evaluate(0, 3)

    refute ReviewConvergence.actionable_thread?(:malformed)
  end

  test "missing metadata is held even at the same-PR retry limit" do
    assert {:hold,
            %{
              same_pr_findings: [],
              held_findings: [%{route: :human_hold, evidence_code: :missing_disposition}]
            }} =
             snapshot(%{threads: [held_finding()]})
             |> ReviewConvergence.evaluate(3, 3)
  end

  test "untrusted and stale dispositions fail closed while a verified same-PR finding remains repairable" do
    untrusted =
      same_pr_finding(%{
        thread_id: "thread-untrusted",
        finding_comment_id: "comment-untrusted",
        disposition_actor: %{
          "login" => "human-reviewer",
          "__typename" => "User",
          "databaseId" => 77
        }
      })

    stale_payload =
      same_pr_payload()
      |> put_in(["binding", "head_sha"], "stale-head")

    stale =
      same_pr_finding(%{
        thread_id: "thread-stale",
        finding_comment_id: "comment-stale",
        disposition: {:decoded, stale_payload}
      })

    assert {:rework,
            %{
              same_pr_findings: [%{thread_id: "thread-same", route: :same_pr}],
              held_findings: held
            }} =
             snapshot(%{threads: [untrusted, same_pr_finding(), stale]})
             |> ReviewConvergence.evaluate(0, 3)

    assert Enum.map(held, &{&1.thread_id, &1.evidence_code}) == [
             {"thread-untrusted", :untrusted_disposition_actor},
             {"thread-stale", :binding_mismatch}
           ]
  end

  test "verified same-PR evidence exposes only canonical typed cluster IDs to rework" do
    assert {:rework,
            %{
              cluster_ids: [@cluster_current_diff, @cluster_ac_1],
              clusters: [
                %{cluster_id: @cluster_current_diff, key: {:current_pr_diff, "lib/current.ex"}},
                %{
                  cluster_id: @cluster_ac_1,
                  key: {:scope_reference, :acceptance_criterion, "AC-1"}
                }
              ]
            }} =
             snapshot(%{threads: [same_pr_finding(), current_diff_finding()]})
             |> ReviewConvergence.evaluate(empty_convergence_history(), 3)
  end

  test "any exact-head cluster overlap holds the whole issue, including mixed repeated and new clusters" do
    history =
      empty_convergence_history(%{
        rework_count: 1,
        last_completed_rework: completed_rework(@operation_head_a, 1, @head_sha, [@cluster_ac_1]),
        completed_cluster_ids_by_head: %{@head_sha => MapSet.new([@cluster_ac_1])}
      })

    assert {:convergence_hold,
            %{
              reason: :repeated_cluster,
              cluster_ids: [@cluster_current_diff, @cluster_ac_1],
              repeated_cluster_ids: [@cluster_ac_1]
            }} =
             snapshot(%{threads: [same_pr_finding(), current_diff_finding()]})
             |> ReviewConvergence.evaluate(history, 3)
  end

  test "a previous completed cluster holds the whole mixed finding set on a new head" do
    history =
      empty_convergence_history(%{
        rework_count: 1,
        last_completed_rework: completed_rework(@operation_head_a, 1, @head_sha, [@cluster_ac_1]),
        completed_cluster_ids_by_head: %{@head_sha => MapSet.new([@cluster_ac_1])}
      })

    assert {:convergence_hold,
            %{
              reason: :repeated_cluster,
              cluster_ids: [@cluster_current_diff, @cluster_ac_1],
              repeated_cluster_ids: [@cluster_ac_1]
            }} =
             snapshot(%{
               current_head_sha: @new_head_sha,
               reviewed_head_sha: @new_head_sha,
               threads: [
                 same_pr_finding_for_head(@new_head_sha),
                 current_diff_finding(@new_head_sha)
               ]
             })
             |> ReviewConvergence.evaluate(history, 3)
  end

  test "exhausted typed budget, malformed ledger, legacy rounds, and persisted holds all fail closed" do
    finding = same_pr_finding()

    exhausted = empty_convergence_history(%{rework_count: 3})

    assert {:convergence_hold, %{reason: :fix_round_budget_exhausted}} =
             snapshot(%{threads: [finding]}) |> ReviewConvergence.evaluate(exhausted, 3)

    invalid = empty_convergence_history(%{ledger_error: :completion_manifest_mismatch})

    assert {:convergence_hold, %{reason: :invalid_ledger}} =
             snapshot() |> ReviewConvergence.evaluate(invalid, 3)

    legacy = empty_convergence_history(%{legacy_rework_count: 1})

    assert {:convergence_hold, %{reason: :legacy_rework_without_manifest}} =
             snapshot() |> ReviewConvergence.evaluate(legacy, 3)

    persisted_hold = %{
      kind: :convergence_hold,
      hold_id: @hold_id,
      head_sha: @head_sha,
      reason: :repeated_cluster,
      cluster_ids: [@cluster_ac_1]
    }

    held = empty_convergence_history(%{holds_by_head: %{@head_sha => persisted_hold}})

    assert {:convergence_hold, %{reason: :persisted_convergence_hold, persisted_hold: ^persisted_hold}} =
             snapshot() |> ReviewConvergence.evaluate(held, 3)
  end

  test "an invalid Scope Contract holds every actionable finding without requesting another review" do
    assert {:hold,
            %{
              same_pr_findings: [],
              held_findings: [%{route: :human_hold, evidence_code: :invalid_scope_contract}]
            }} =
             snapshot(%{
               scope_contract: {:error, [:missing_scope_contract]},
               reviewed_head_sha: nil,
               review_result: :missing,
               threads: [same_pr_finding()]
             })
             |> ReviewConvergence.evaluate(0, 3)
  end

  test "an unverified remote base claim fails closed" do
    result =
      snapshot(%{base_verification_required: true, base_verification: :unverified})
      |> ReviewConvergence.evaluate(0, 3)

    assert {:wait, %{reason: :base_unverified, base_ref_oid: "base"}} = result
  end

  test "base-missing claims verify absence rather than presence" do
    base_paths = MapSet.new(["lib/present.ex", "README.md"])

    assert GitHubReviewClient.missing_paths_verified_for_test?(base_paths, ["lib/missing.ex"])
    refute GitHubReviewClient.missing_paths_verified_for_test?(base_paths, ["lib/present.ex"])
  end

  test "base verification resolves a commit payload to its tree oid" do
    assert GitHubReviewClient.base_tree_oid_for_test(%{"tree" => %{"sha" => "tree-sha"}}) ==
             {:ok, "tree-sha"}

    assert {:error, {:missing_base_tree_oid, _}} =
             GitHubReviewClient.base_tree_oid_for_test(%{"sha" => "commit-sha"})
  end

  test "actionable findings comment and return the issue for repair once per head and finding" do
    finding = same_pr_finding(%{body: "P1 data loss", url: "https://example.test/thread"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :failure, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "P1"
    assert_receive {:comment, "issue-160", intent_body}
    assert intent_body =~ "transition-operation: `intent`"
    assert {:ok, intent_event} = ReviewConvergenceLedger.parse_comment(intent_body)
    assert intent_event.kind == :rework_intent
    assert intent_event.round == 1
    assert intent_event.head_sha == @head_sha
    assert intent_event.cluster_ids == [@cluster_ac_1]
    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", transition_body}
    assert transition_body =~ "returned this issue to In Progress"
    assert transition_body =~ "transition-operation: `completed`"
    assert {:ok, completed_event} = ReviewConvergenceLedger.parse_comment(transition_body)
    assert completed_event.kind == :rework_completed
    assert completed_event.operation_id == intent_event.operation_id
    assert completed_event.cluster_ids == intent_event.cluster_ids

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "a repeated exact-head cluster writes one durable Convergence Hold and never moves state or rereviews" do
    completed = completed_rework(@operation_head_a, 1, @head_sha, [@cluster_ac_1])

    history =
      empty_convergence_history(%{
        rework_count: 1,
        last_completed_rework: completed,
        completed_cluster_ids_by_head: %{@head_sha => MapSet.new([@cluster_ac_1])}
      })

    Application.put_env(:symphony_elixir, :review_history, {:ok, history})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [same_pr_finding()]})})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:status, _, @head_sha, :failure, _}
    assert_receive {:comment, "issue-160", hold_comment}
    assert hold_comment =~ "Convergence Hold"
    assert hold_comment =~ "repeated_cluster"
    assert {:ok, hold_event} = ReviewConvergenceLedger.parse_comment(hold_comment)
    assert hold_event.kind == :convergence_hold
    assert hold_event.head_sha == @head_sha
    assert hold_event.cluster_ids == [@cluster_ac_1]
    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
    assert state["issue-160"].fix_rounds == 1

    restarted_history =
      history
      |> Map.put(:dedup, MapSet.new([hold_event.hold_id]))
      |> Map.put(:holds_by_head, %{@head_sha => hold_event})

    Application.put_env(:symphony_elixir, :review_history, {:ok, restarted_history})

    _restarted = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :failure, _}
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "malformed durable ledger creates a Convergence Hold without state or review effects" do
    history = empty_convergence_history(%{ledger_error: :completion_manifest_mismatch})
    Application.put_env(:symphony_elixir, :review_history, {:ok, history})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:status, _, @head_sha, :failure, _}
    assert_receive {:comment, "issue-160", hold_comment}
    assert hold_comment =~ "Convergence Hold"
    assert hold_comment =~ "invalid_ledger"

    assert {:ok, %{kind: :convergence_hold, reason: :invalid_ledger, cluster_ids: []}} =
             ReviewConvergenceLedger.parse_comment(hold_comment)

    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "hold-only findings publish one stable comment and consume no repair round or rereview" do
    finding = held_finding(%{body: "P1 first wording", url: "https://example.test/held"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:status, _, @head_sha, :pending, _}
    assert_receive {:comment, "issue-160", comment}
    assert comment =~ "held review findings"
    assert comment =~ "missing_disposition"
    assert comment =~ "https://example.test/held"
    refute_receive {:review_requested, _, _, _}
    refute_receive {:state, _, _}
    assert state["issue-160"].fix_rounds == 0

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:comment, _, _}
    refute_receive {:review_requested, _, _, _}
    refute_receive {:state, _, _}
  end

  test "held-finding restart dedup is independent of prose wording" do
    first = held_finding(%{body: "P1 original wording"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [first]})})

    first_state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :pending, _}
    assert_receive {:comment, "issue-160", _comment}

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, %{dedup: first_state["issue-160"].dedup, rework_count: 0}}
    )

    rewritten = held_finding(%{body: "P1 completely rewritten prose"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [rewritten]})})

    restarted = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :pending, _}
    refute_receive {:comment, _, _}
    refute_receive {:review_requested, _, _, _}
    refute_receive {:state, _, _}
    assert restarted["issue-160"].fix_rounds == 0
  end

  test "mixed findings persist held evidence separately before repairing only verified same-PR work" do
    held = held_finding(%{url: "https://example.test/held"})
    same_pr = same_pr_finding(%{url: "https://example.test/same-pr"})

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{threads: [held, same_pr]})}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:status, _, @head_sha, :failure, _}
    assert_receive {:comment, "issue-160", held_comment}
    assert held_comment =~ "held review findings"
    assert held_comment =~ "https://example.test/held"

    assert_receive {:comment, "issue-160", rework_comment}
    assert rework_comment =~ "https://example.test/same-pr"
    refute rework_comment =~ "https://example.test/held"

    assert_receive {:comment, "issue-160", intent_comment}
    assert intent_comment =~ "transition-operation: `intent`"
    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", completed_comment}
    assert completed_comment =~ "transition-operation: `completed`"

    assert state["issue-160"].fix_rounds == 1
    assert state["issue-160"].last_finding_fingerprint == [@cluster_ac_1]

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
  end

  test "state transition retries after the rework comment already persisted" do
    finding = same_pr_finding(%{body: "P1 state retry", url: "thread"})
    fingerprint = [@cluster_ac_1]
    key = ReviewConvergence.dedup_key(:rework, "issue-160", @head_sha, fingerprint)
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :review_state_result, {:error, :linear_unavailable})

    first_state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", rework_body}
    assert rework_body =~ "actionable latest-head findings"
    assert_receive {:comment, "issue-160", intent_body}
    assert intent_body =~ "transition-operation: `intent`"
    assert {:ok, first_intent} = ReviewConvergenceLedger.parse_comment(intent_body)
    assert first_intent.cluster_ids == [@cluster_ac_1]
    assert_receive {:state, "issue-160", "In Progress"}
    assert first_state["issue-160"].fix_rounds == 0

    transition_key = first_intent.operation_id
    intent_key = "transition-intent:#{transition_key}"

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       empty_convergence_history(%{
         dedup: MapSet.new([key, intent_key]),
         pending_transitions: %{transition_key => first_intent}
       })}
    )

    Application.put_env(:symphony_elixir, :review_state_result, :ok)

    second_state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", transition_body}
    assert transition_body =~ "returned this issue to In Progress"
    assert {:ok, resumed_completion} = ReviewConvergenceLedger.parse_comment(transition_body)
    assert resumed_completion.operation_id == first_intent.operation_id
    assert resumed_completion.cluster_ids == first_intent.cluster_ids
    assert second_state["issue-160"].fix_rounds == 1

    Application.put_env(:symphony_elixir, :review_issues, [%{issue() | state: "In Progress"}])

    Application.put_env(:symphony_elixir, :review_history, {
      :ok,
      empty_convergence_history(%{
        dedup: MapSet.new([key, transition_key]),
        rework_count: 1,
        last_completed_rework: resumed_completion,
        completed_cluster_ids_by_head: %{@head_sha => MapSet.new([@cluster_ac_1])}
      })
    })

    restarted = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
    assert restarted == %{}
  end

  test "state transition completion requires authoritative target-state readback" do
    finding = same_pr_finding(%{body: "P1 state race", url: "thread"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})
    Application.put_env(:symphony_elixir, :verified_issue_state, "In Review")

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:comment, "issue-160", _rework}
    assert_receive {:comment, "issue-160", intent}
    assert intent =~ "transition-operation: `intent`"
    assert_receive {:state, "issue-160", "In Progress"}
    refute_receive {:comment, "issue-160", _completion}
    assert state["issue-160"].fix_rounds == 0
  end

  test "pending transition completes after restart even after the issue left review" do
    operation_id = @operation_head_a

    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       %{
         dedup: MapSet.new(["transition-intent:#{operation_id}"]),
         rework_count: 0,
         pending_transitions: %{
           operation_id => %{
             kind: :rework_intent,
             operation_id: operation_id,
             round: 1,
             head_sha: @head_sha,
             target_state: "In Progress",
             cluster_ids: [@cluster_ac_1]
           }
         }
       }}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:comment, "issue-160", completion}
    assert completion =~ "transition-operation: `completed`"
    assert completion =~ "transition-operation-id: `#{operation_id}`"

    assert {:ok, %{kind: :rework_completed, cluster_ids: [@cluster_ac_1]}} =
             ReviewConvergenceLedger.parse_comment(completion)

    refute_receive {:state, _, _}
    refute_receive {:status, _, _, _, _}
    assert state["issue-160"].fix_rounds == 1
  end

  test "pending transition retries the state move before recording completion" do
    operation_id = @operation_head_b

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       %{
         dedup: MapSet.new(["transition-intent:#{operation_id}"]),
         rework_count: 0,
         pending_transitions: %{
           operation_id => %{
             kind: :rework_intent,
             operation_id: operation_id,
             round: 1,
             head_sha: @new_head_sha,
             target_state: "In Progress",
             cluster_ids: [@cluster_ac_1]
           }
         }
       }}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:state, "issue-160", "In Progress"}
    assert_receive {:comment, "issue-160", completion}
    assert completion =~ "transition-operation: `completed`"

    assert {:ok, %{kind: :rework_completed, cluster_ids: [@cluster_ac_1]}} =
             ReviewConvergenceLedger.parse_comment(completion)

    assert state["issue-160"].fix_rounds == 1
  end

  test "stale pending history does not recount an already deduplicated completion" do
    operation_id = @operation_head_c

    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       %{
         dedup: MapSet.new(["transition-intent:#{operation_id}", operation_id]),
         rework_count: 1,
         pending_transitions: %{
           operation_id => %{
             kind: :rework_intent,
             operation_id: operation_id,
             round: 1,
             head_sha: String.duplicate("c", 40),
             target_state: "In Progress",
             cluster_ids: [@cluster_ac_1]
           }
         }
       }}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    refute_receive {:comment, _, _}
    refute_receive {:state, _, _}
    assert state["issue-160"].fix_rounds == 1
  end

  test "pending recovery rejects a forged target state without moving the issue" do
    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       empty_convergence_history(%{
         pending_transitions: %{
           @operation_head_a => %{
             kind: :rework_intent,
             operation_id: @operation_head_a,
             round: 1,
             head_sha: @head_sha,
             target_state: "Done",
             cluster_ids: [@cluster_ac_1]
           }
         }
       })}
    )

    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:comment, "issue-160", hold_comment}
    assert hold_comment =~ "invalid_ledger"
    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "pending recovery rejects a syntactically valid forged operation without moving the issue" do
    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok,
       empty_convergence_history(%{
         pending_transitions: %{
           @forged_operation => %{
             kind: :rework_intent,
             operation_id: @forged_operation,
             round: 1,
             head_sha: @head_sha,
             target_state: "In Progress",
             cluster_ids: [@cluster_ac_1]
           }
         }
       })}
    )

    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)

    assert_receive {:comment, "issue-160", hold_comment}
    assert hold_comment =~ "invalid_ledger"
    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "ordinary In Progress issue ignores review-history outages" do
    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})

    assert ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker) == %{}
    refute_receive {:comment, _, _}
    refute_receive {:status, _, _, _, _}
    refute_receive {:state, _, _}
  end

  test "known pending transition still fails closed on a history outage" do
    Application.put_env(:symphony_elixir, :review_issues, [
      %{issue() | state: "In Progress"}
    ])

    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})
    Application.put_env(:symphony_elixir, :review_snapshot, {:error, :github_unavailable})

    state = %{
      "issue-160" => %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: @head_sha,
        fetch_failed: false,
        waiting: false,
        review_requested: false,
        last_finding_fingerprint: nil,
        pending_transitions: %{"operation" => %{target_state: "In Progress"}}
      }
    }

    result = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :error, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "linear_unavailable"
    assert result["issue-160"].waiting
  end

  test "waiting on environment or human judgment neither rereviews nor changes state" do
    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{waiting_reason: :staging, reviewed_head_sha: nil, review_result: :missing})}
    )

    state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :pending, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "waiting for team human judgment"
    assert body =~ "staging"
    refute_receive {:review_requested, _, _, _}
    refute_receive {:state, _, _}

    _state = ReviewMonitor.run_with(state, settings(), ReviewClient, Tracker)
    refute_receive {:status, _, _, _, _}
    refute_receive {:comment, _, _}
  end

  test "exhausted typed fix-round budget creates a Convergence Hold instead of scheduling repair" do
    finding = same_pr_finding_for_head(@new_head_sha)

    Application.put_env(
      :symphony_elixir,
      :review_snapshot,
      {:ok, snapshot(%{current_head_sha: @new_head_sha, threads: [finding]})}
    )

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, empty_convergence_history(%{rework_count: 3})}
    )

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @new_head_sha, :failure, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "Convergence Hold"
    assert body =~ "fix_round_budget_exhausted"
    assert {:ok, %{kind: :convergence_hold}} = ReviewConvergenceLedger.parse_comment(body)
    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "legacy rework count without typed manifests creates a Convergence Hold" do
    finding = same_pr_finding(%{priority: 2, body: "P2 recurring patch", url: "thread"})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot(%{threads: [finding]})})

    Application.put_env(
      :symphony_elixir,
      :review_history,
      {:ok, empty_convergence_history(%{legacy_rework_count: 3})}
    )

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:comment, "issue-160", body}
    assert body =~ "legacy_rework_without_manifest"
    refute_receive {:state, _, _}
    refute_receive {:review_requested, _, _, _}
  end

  test "unverifiable persisted rework history fails closed" do
    Application.put_env(:symphony_elixir, :review_history, {:error, :linear_unavailable})
    Application.put_env(:symphony_elixir, :review_snapshot, {:ok, snapshot()})

    _state = ReviewMonitor.run_with(%{}, settings(), ReviewClient, Tracker)
    assert_receive {:status, _, @head_sha, :error, _}
    assert_receive {:comment, "issue-160", body}
    assert body =~ "linear_unavailable"
    refute_receive {:state, _, _}
  end

  defp settings do
    %{
      repository: "aroakpm-svg/repo",
      review_state: "In Review",
      in_progress_state: "In Progress",
      max_fix_rounds: 3,
      human_owner: "owner"
    }
  end

  defp review_request_comment(head) do
    %{
      "body" => "@codex review\n\ndedup-key: `aro-160-review-#{head}`",
      "created_at" => "2026-07-22T01:00:00Z"
    }
  end

  defp clean_attestation_comment(reviewed_prefix) do
    %{
      "body" => "Codex Review: Didn't find any major issues. Another round soon, please!\n\n**Reviewed commit:** `#{reviewed_prefix}`",
      "created_at" => "2026-07-22T01:05:00Z",
      "user" => %{
        "login" => "chatgpt-codex-connector[bot]",
        "type" => "Bot",
        "id" => 199_175_422
      },
      "performed_via_github_app" => %{
        "slug" => "chatgpt-codex-connector",
        "id" => 1_144_995
      }
    }
  end

  defp issue do
    %Issue{
      id: "issue-160",
      identifier: "ARO-160",
      title: "Review convergence",
      state: "In Review",
      branch_name: "codex/aro-160",
      url: "https://linear.test/ARO-160",
      labels: ["owned"]
    }
  end

  defp scope_contract do
    %ScopeContract{
      work_item: "Route verified review findings.",
      invariants: ["Preserve tenant boundaries."],
      acceptance_criteria: ["AC-1: Fix verified finding."],
      non_goals: ["Do not infer scope from prose."],
      dependencies: ["PR #8 is merged."],
      follow_ups: []
    }
  end

  defp scope_contract_body do
    """
    #### Scope Contract

    ##### Work Item

    Route verified review findings.

    ##### Invariants

    - Preserve tenant boundaries.

    ##### Acceptance Criteria

    - AC-1: Fix verified finding.

    ##### Non-Goals

    - Do not infer scope from prose.

    ##### Dependencies

    - PR #8 is merged.

    ##### Follow-Ups

    None
    """
  end

  defp trusted_actor do
    %{
      "login" => "chatgpt-codex-connector[bot]",
      "__typename" => "Bot",
      "databaseId" => 199_175_422
    }
  end

  defp same_pr_payload do
    %{
      "schema_version" => 1,
      "kind" => "same_pr",
      "binding" => %{
        "base_sha" => "base",
        "head_sha" => @head_sha,
        "path" => "lib/example.ex"
      },
      "scope_ref" => %{"type" => "acceptance_criterion", "id" => "AC-1"}
    }
  end

  defp same_pr_finding(overrides \\ %{}) do
    Map.merge(
      %{
        resolved: false,
        priority: 1,
        body: "P1 verified same-PR finding",
        path: "lib/example.ex",
        url: "https://example.test/same-pr",
        commit_sha: @head_sha,
        thread_id: "thread-same",
        finding_comment_id: "comment-same",
        disposition_actor: trusted_actor(),
        disposition: {:decoded, same_pr_payload()}
      },
      overrides
    )
  end

  defp same_pr_finding_for_head(head_sha) do
    payload = put_in(same_pr_payload(), ["binding", "head_sha"], head_sha)
    same_pr_finding(%{disposition: {:decoded, payload}, commit_sha: head_sha})
  end

  defp current_diff_finding(head_sha \\ @head_sha) do
    payload = %{
      "schema_version" => 1,
      "kind" => "introduced_by_pr",
      "binding" => %{
        "base_sha" => "base",
        "head_sha" => head_sha,
        "path" => "lib/current.ex"
      },
      "proof" => %{"type" => "current_pr_diff"}
    }

    same_pr_finding(%{
      path: "lib/current.ex",
      commit_sha: head_sha,
      thread_id: "thread-current-diff",
      finding_comment_id: "comment-current-diff",
      disposition: {:decoded, payload}
    })
  end

  defp held_finding(overrides \\ %{}) do
    Map.merge(
      %{
        resolved: false,
        priority: 1,
        body: "P1 finding without disposition metadata",
        path: "lib/held.ex",
        url: "https://example.test/held",
        commit_sha: @head_sha,
        thread_id: "thread-held",
        finding_comment_id: "comment-held",
        disposition_actor: trusted_actor(),
        disposition: :missing
      },
      overrides
    )
  end

  defp empty_convergence_history(overrides \\ %{}) do
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
      overrides
    )
  end

  defp completed_rework(operation_id, round, head_sha, cluster_ids) do
    %{
      kind: :rework_completed,
      operation_id: operation_id,
      round: round,
      head_sha: head_sha,
      target_state: "In Progress",
      cluster_ids: Enum.sort(cluster_ids)
    }
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        repository: "aroakpm-svg/repo",
        pull_request_number: 42,
        current_head_sha: @head_sha,
        reviewed_head_sha: @head_sha,
        review_result: :no_major_issues,
        base_ref_oid: "base",
        base_verification_required: false,
        base_verification: :not_required,
        scope_contract: {:ok, scope_contract()},
        required_checks: [%{name: "test", state: :success}],
        threads: [],
        waiting_reason: nil
      },
      overrides
    )
  end

  defp rework_body(key) do
    %{"body" => "Review Convergence Gate returned this issue to In Progress for latest-head repair.\n\ndedup-key: `#{key}`"}
  end

  defp transition_intent_body(operation_id, head_sha, round, cluster_ids) do
    %{
      "body" => """
      Review Convergence Gate recorded a durable rework transition intent.
      currentHeadSha: `#{head_sha}`
      target-state: `In Progress`
      transition-operation: `intent`
      transition-operation-id: `#{operation_id}`
      dedup-key: `transition-intent:#{operation_id}`

      #{ledger_block(%{"schema_version" => 1, "event" => "rework_intent", "operation_id" => operation_id, "round" => round, "head_sha" => head_sha, "target_state" => "In Progress", "cluster_ids" => Enum.sort(cluster_ids)})}
      """
    }
  end

  defp transition_completed_body(operation_id, head_sha, round, cluster_ids) do
    %{
      "body" => """
      Review Convergence Gate returned this issue to In Progress for latest-head repair.
      currentHeadSha: `#{head_sha}`
      transition-operation: `completed`
      transition-operation-id: `#{operation_id}`
      dedup-key: `#{operation_id}`

      #{ledger_block(%{"schema_version" => 1, "event" => "rework_completed", "operation_id" => operation_id, "round" => round, "head_sha" => head_sha, "target_state" => "In Progress", "cluster_ids" => Enum.sort(cluster_ids)})}
      """
    }
  end

  defp ledger_block(payload) do
    "<!-- symphony-review-convergence-ledger:v1\n#{Jason.encode!(payload)}\n-->"
  end

  defp converged_body(head_sha) do
    %{
      "body" => "Review Convergence Gate reports technical convergence.\ncurrentHeadSha = reviewedHeadSha = `#{head_sha}`\ndedup-key: `converged`"
    }
  end

  defp history_page(nodes, has_next, cursor) do
    %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => nodes,
            "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}
          }
        }
      }
    }
  end
end
