defmodule SymphonyElixir.FindingRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FindingRouter
  alias SymphonyElixir.ScopeContract

  @contract %ScopeContract{
    work_item: "Route typed findings.",
    invariants: ["Preserve tenant boundaries."],
    acceptance_criteria: ["AC-1: Route verified findings.", "AC-2: Fail closed."],
    non_goals: ["Do not infer scope from prose."],
    dependencies: ["PR #8 is merged."],
    follow_ups: []
  }

  @binding %{base_sha: "base-123", head_sha: "head-456"}

  @trusted_actor %{
    "login" => "chatgpt-codex-connector[bot]",
    "__typename" => "Bot",
    "databaseId" => 199_175_422
  }

  @same_pr_payload %{
    "schema_version" => 1,
    "kind" => "same_pr",
    "binding" => %{
      "base_sha" => "base-123",
      "head_sha" => "head-456",
      "path" => "lib/router.ex"
    },
    "scope_ref" => %{"type" => "acceptance_criterion", "id" => "AC-2"}
  }

  test "extracts one exact v1 disposition block into decoded untrusted data" do
    # Mutations caught: accepting arbitrary comment JSON or requiring the adapter to decode a second schema copy.
    body = """
    Reviewer explanation stays display-only.
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"human_hold","binding":{"base_sha":"base-123","head_sha":"head-456","path":"lib/router.ex"}}
    -->
    """

    assert {:decoded,
            %{
              "schema_version" => 1,
              "kind" => "human_hold",
              "binding" => %{
                "base_sha" => "base-123",
                "head_sha" => "head-456",
                "path" => "lib/router.ex"
              }
            }} = FindingRouter.extract_disposition(body)
  end

  test "does not recognize near-match sentinels or examples inside Markdown fences" do
    # Mutations caught: substring matching a schema marker shown as prose or code instead of emitted metadata.
    near_match = """
    <!-- symphony-finding-disposition:v2
    {"schema_version":1}
    -->
    """

    fenced = """
    ```text
    <!-- symphony-finding-disposition:v1
    {"schema_version":1}
    -->
    ```
    """

    assert :missing = FindingRouter.extract_disposition(near_match)
    assert :missing = FindingRouter.extract_disposition(fenced)
  end

  test "closes fenced examples only with CommonMark marker and ASCII whitespace rules" do
    # Mutations caught: trimming Unicode whitespace, accepting short markers, or allowing four-space indentation.
    disposition = """
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"human_hold","binding":{"base_sha":"base-123","head_sha":"head-456","path":"lib/router.ex"}}
    -->
    """

    valid_closers = [
      {"```json", "```"},
      {"```json", " ````"},
      {"```json", "  ```\t"},
      {"```json", "   ``` \t"},
      {"~~~~text", "~~~~~"}
    ]

    for {opening, closing} <- valid_closers do
      assert {:decoded, %{"kind" => "human_hold"}} =
               FindingRouter.extract_disposition("#{opening}\n#{closing}\n#{disposition}")
    end

    invalid_closers = [
      {"````json", "```"},
      {"```json", "    ```"},
      {"```json", "```\u00A0"},
      {"~~~text", "~~~\u2003"},
      {"~~~text", "```"}
    ]

    for {opening, false_closing} <- invalid_closers do
      body = "#{opening}\n#{false_closing}\n#{disposition}\n#{String.slice(opening, 0, 3)}"
      assert :missing = FindingRouter.extract_disposition(body)
    end
  end

  test "rejects duplicate JSON members at the top level and in nested objects" do
    # Mutations caught: decoding to maps before checking ambiguity or checking only root object keys.
    top_level_duplicate = """
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"same_pr","kind":"human_hold","binding":{"base_sha":"base-123","head_sha":"head-456","path":"lib/router.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-2"}}
    -->
    """

    nested_duplicate = """
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"same_pr","binding":{"base_sha":"base-123","head_sha":"head-456","path":"lib/router.ex","path":"lib/other.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-2"}}
    -->
    """

    assert {:error, :malformed} = FindingRouter.extract_disposition(top_level_duplicate)
    assert {:error, :malformed} = FindingRouter.extract_disposition(nested_duplicate)
  end

  test "routes extracted duplicate JSON members to human hold" do
    # Mutations caught: allowing duplicate members to retain a same-PR ownership claim after normalization.
    duplicate_blocks = [
      """
      <!-- symphony-finding-disposition:v1
      {"schema_version":1,"kind":"same_pr","kind":"human_hold","binding":{"base_sha":"base-123","head_sha":"head-456","path":"lib/router.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-2"}}
      -->
      """,
      """
      <!-- symphony-finding-disposition:v1
      {"schema_version":1,"kind":"same_pr","binding":{"base_sha":"base-123","head_sha":"head-456","path":"lib/router.ex","path":"lib/other.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-2"}}
      -->
      """
    ]

    for {body, index} <- Enum.with_index(duplicate_blocks, 1) do
      finding = %{
        thread_id: "thread-duplicate-member-#{index}",
        finding_comment_id: "comment-duplicate-member-#{index}",
        disposition_actor: @trusted_actor,
        disposition: FindingRouter.extract_disposition(body),
        priority: 1,
        path: "lib/router.ex",
        url: "https://example.test/duplicate-member-#{index}"
      }

      assert %{route: :human_hold, evidence_code: :malformed_disposition} =
               FindingRouter.route(@contract, finding, @binding)
    end
  end

  test "fails closed on malformed, duplicate, and oversized disposition blocks" do
    # Mutations caught: selecting one duplicate, recovering invalid JSON, or parsing an unbounded comment payload.
    malformed = """
    <!-- symphony-finding-disposition:v1
    {not-json}
    -->
    """

    unterminated = """
    <!-- symphony-finding-disposition:v1
    {"schema_version":1}
    """

    duplicate = """
    <!-- symphony-finding-disposition:v1
    {"schema_version":1}
    -->
    <!-- symphony-finding-disposition:v1
    {"schema_version":1}
    -->
    """

    oversized = """
    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"padding":"#{String.duplicate("x", 9_000)}"}
    -->
    """

    assert {:error, :malformed} = FindingRouter.extract_disposition(malformed)
    assert {:error, :malformed} = FindingRouter.extract_disposition(unterminated)
    assert {:error, :duplicate} = FindingRouter.extract_disposition(duplicate)
    assert {:error, :too_large} = FindingRouter.extract_disposition(oversized)
  end

  test "routes a trusted exact acceptance-criterion disposition to the same PR" do
    # Mutations caught: routing every actionable priority to rework or dropping exact Scope Contract verification.
    finding = %{
      thread_id: "thread-17",
      finding_comment_id: "comment-23",
      disposition_actor: @trusted_actor,
      disposition: {:decoded, @same_pr_payload},
      priority: 2,
      path: "lib/router.ex",
      url: "https://example.test/review/comment-23",
      body: "P2 arbitrary reviewer prose"
    }

    assert %{
             route: :same_pr,
             evidence_code: :scope_contract_reference_verified,
             evidence_display: "Scope Contract acceptance criterion AC-2",
             original_kind: :same_pr,
             thread_id: "thread-17",
             finding_comment_id: "comment-23",
             priority: 2,
             path: "lib/router.ex",
             url: "https://example.test/review/comment-23",
             evidence: %{
               binding: %{base_sha: "base-123", head_sha: "head-456", path: "lib/router.ex"},
               scope_reference: {:acceptance_criterion, "AC-2"}
             }
           } = FindingRouter.route(@contract, finding, @binding)

    refute Map.has_key?(FindingRouter.route(@contract, finding, @binding), :body)
  end

  test "routes an exact invariant disposition to the same PR" do
    # Mutation caught: allowing only acceptance-criterion references for same-PR findings.
    payload = %{
      "schema_version" => 1,
      "kind" => "same_pr",
      "binding" => %{
        "base_sha" => "base-123",
        "head_sha" => "head-456",
        "path" => "lib/router.ex"
      },
      "scope_ref" => %{"type" => "invariant", "value" => "Preserve tenant boundaries."}
    }

    finding = %{
      thread_id: "thread-invariant",
      finding_comment_id: "comment-invariant",
      disposition_actor: @trusted_actor,
      disposition: {:decoded, payload},
      priority: 1,
      path: "lib/router.ex",
      url: "https://example.test/invariant"
    }

    assert %{
             route: :same_pr,
             evidence_code: :scope_contract_reference_verified,
             original_kind: :same_pr,
             evidence: %{scope_reference: {:invariant, "Preserve tenant boundaries."}}
           } = FindingRouter.route(@contract, finding, @binding)
  end

  test "maps a verified introduced-by-PR disposition to same PR while preserving its kind" do
    # Mutations caught: routing introduced work to a held partition or rewriting its original kind.
    payload = %{
      "schema_version" => 1,
      "kind" => "introduced_by_pr",
      "binding" => %{
        "base_sha" => "base-123",
        "head_sha" => "head-456",
        "path" => "lib/router.ex"
      },
      "proof" => %{"type" => "current_pr_diff"}
    }

    finding = %{
      thread_id: "thread-introduced",
      finding_comment_id: "comment-introduced",
      disposition_actor: @trusted_actor,
      disposition: {:decoded, payload},
      priority: 4,
      path: "lib/router.ex",
      url: "https://example.test/introduced"
    }

    assert %{
             route: :same_pr,
             evidence_code: :current_pr_diff_verified,
             evidence_display: "Current PR diff at lib/router.ex",
             original_kind: :introduced_by_pr,
             evidence: %{
               binding: %{base_sha: "base-123", head_sha: "head-456", path: "lib/router.ex"},
               proof: :current_pr_diff
             }
           } = FindingRouter.route(@contract, finding, @binding)
  end

  test "routes an exact dependency disposition to the prerequisite hold partition" do
    # Mutation caught: returning prerequisite work to the current implementation branch.
    payload = %{
      "schema_version" => 1,
      "kind" => "prerequisite",
      "binding" => %{
        "base_sha" => "base-123",
        "head_sha" => "head-456",
        "path" => "lib/router.ex"
      },
      "scope_ref" => %{"type" => "dependency", "value" => "PR #8 is merged."}
    }

    finding = %{
      thread_id: "thread-prerequisite",
      finding_comment_id: "comment-prerequisite",
      disposition_actor: @trusted_actor,
      disposition: {:decoded, payload},
      priority: 3,
      path: "lib/router.ex",
      url: "https://example.test/prerequisite"
    }

    assert %{
             route: :prerequisite,
             evidence_code: :scope_contract_dependency_verified,
             evidence_display: "Scope Contract dependency: PR #8 is merged.",
             original_kind: :prerequisite,
             evidence: %{scope_reference: {:dependency, "PR #8 is merged."}}
           } = FindingRouter.route(@contract, finding, @binding)
  end

  test "routes both permitted follow-up relations to the follow-up hold partition" do
    # Mutation caught: accepting just one documented follow-up relation or treating follow-up work as same-PR work.
    for relation <- ["adjacent", "pre_existing"] do
      payload = %{
        "schema_version" => 1,
        "kind" => "follow_up",
        "binding" => %{
          "base_sha" => "base-123",
          "head_sha" => "head-456",
          "path" => "lib/router.ex"
        },
        "relation" => relation
      }

      finding = %{
        thread_id: "thread-follow-up-#{relation}",
        finding_comment_id: "comment-follow-up-#{relation}",
        disposition_actor: @trusted_actor,
        disposition: {:decoded, payload},
        priority: 2,
        path: "lib/router.ex",
        url: "https://example.test/follow-up/#{relation}"
      }

      assert %{
               route: :follow_up,
               evidence_code: :follow_up_relation_verified,
               original_kind: :follow_up,
               evidence: %{relation: expected_relation}
             } = FindingRouter.route(@contract, finding, @binding)

      assert Atom.to_string(expected_relation) == relation
    end
  end

  test "routes an explicit trusted human hold without claiming ownership" do
    # Mutation caught: treating every valid structured payload as current-PR repair work.
    payload = %{
      "schema_version" => 1,
      "kind" => "human_hold",
      "binding" => %{
        "base_sha" => "base-123",
        "head_sha" => "head-456",
        "path" => "lib/router.ex"
      }
    }

    finding = %{
      thread_id: "thread-hold",
      finding_comment_id: "comment-hold",
      disposition_actor: @trusted_actor,
      disposition: {:decoded, payload},
      priority: 1,
      path: "lib/router.ex",
      url: "https://example.test/hold"
    }

    assert %{
             route: :human_hold,
             evidence_code: :explicit_human_hold,
             evidence_display: "Trusted reviewer requested human disposition",
             original_kind: :human_hold
           } = FindingRouter.route(@contract, finding, @binding)
  end

  test "missing metadata stays on human hold even when severity and prose suggest same-PR work" do
    # Mutations caught: classifying by priority, filename, URL, or natural-language phrases.
    finding = %{
      thread_id: "thread-missing",
      finding_comment_id: "comment-missing",
      disposition_actor: @trusted_actor,
      disposition: :missing,
      disposition_actor_trusted?: true,
      priority: 1,
      path: "lib/obviously_same_pr_fix.ex",
      url: "https://example.test/fix-this-in-current-pr",
      body: "P1 introduced by this PR and definitely in scope"
    }

    assert %{
             route: :human_hold,
             evidence_code: :missing_disposition,
             original_kind: nil,
             thread_id: "thread-missing",
             finding_comment_id: "comment-missing"
           } = FindingRouter.route(@contract, finding, @binding)
  end

  test "normalization errors have stable fail-closed reasons" do
    # Mutations caught: treating malformed or duplicate blocks as absent or accepting either as valid metadata.
    malformed = %{
      thread_id: "thread-malformed",
      finding_comment_id: "comment-malformed",
      disposition_actor: @trusted_actor,
      disposition: {:error, :malformed},
      priority: 2,
      path: "lib/router.ex",
      url: "https://example.test/malformed"
    }

    duplicate = %{
      thread_id: "thread-duplicate",
      finding_comment_id: "comment-duplicate",
      disposition_actor: @trusted_actor,
      disposition: {:error, :duplicate},
      priority: 2,
      path: "lib/router.ex",
      url: "https://example.test/duplicate"
    }

    assert %{route: :human_hold, evidence_code: :malformed_disposition} =
             FindingRouter.route(@contract, malformed, @binding)

    assert %{route: :human_hold, evidence_code: :duplicate_disposition} =
             FindingRouter.route(@contract, duplicate, @binding)
  end

  test "only canonical trusted actor identity can authorize a decoded disposition" do
    # Mutation caught: trusting a caller-supplied boolean or actor login without immutable type/database identity.
    finding = %{
      thread_id: "thread-impostor",
      finding_comment_id: "comment-impostor",
      disposition_actor: %{
        "login" => "chatgpt-codex-connector[bot]",
        "__typename" => "Bot",
        "databaseId" => 42
      },
      disposition_actor_trusted?: true,
      disposition: {:decoded, @same_pr_payload},
      priority: 1,
      path: "lib/router.ex",
      url: "https://example.test/impostor"
    }

    assert %{
             route: :human_hold,
             evidence_code: :untrusted_disposition_actor,
             original_kind: nil
           } = FindingRouter.route(@contract, finding, @binding)
  end

  test "unknown schema versions, kinds, and fields fail closed with distinct reasons" do
    # Mutations caught: silently accepting future schema, kind, or field semantics.
    cases = [
      {put_in(@same_pr_payload, ["schema_version"], 2), :unsupported_schema_version},
      {put_in(@same_pr_payload, ["kind"], "same_repository"), :unknown_disposition_kind},
      {Map.put(@same_pr_payload, "severity", "P1"), :unknown_disposition_field}
    ]

    for {payload, expected_code} <- cases do
      finding = %{
        thread_id: "thread-schema-#{expected_code}",
        finding_comment_id: "comment-schema-#{expected_code}",
        disposition_actor: @trusted_actor,
        disposition: {:decoded, payload},
        priority: 1,
        path: "lib/router.ex",
        url: "https://example.test/#{expected_code}"
      }

      assert %{route: :human_hold, evidence_code: ^expected_code} =
               FindingRouter.route(@contract, finding, @binding)
    end
  end

  test "stale SHA, wrong path, and missing GitHub identities fail closed" do
    # Mutations caught: partial binding checks or identity records that can collapse during deduplication.
    cases = [
      {put_in(@same_pr_payload, ["binding", "head_sha"], "old-head"), %{thread_id: "thread-stale", finding_comment_id: "comment-stale", path: "lib/router.ex"}, :binding_mismatch},
      {put_in(@same_pr_payload, ["binding", "path"], "lib/other.ex"), %{thread_id: "thread-path", finding_comment_id: "comment-path", path: "lib/router.ex"}, :binding_mismatch},
      {@same_pr_payload, %{thread_id: "", finding_comment_id: "comment-no-thread", path: "lib/router.ex"}, :missing_finding_identity}
    ]

    for {payload, identity, expected_code} <- cases do
      finding = %{
        thread_id: identity.thread_id,
        finding_comment_id: identity.finding_comment_id,
        disposition_actor: @trusted_actor,
        disposition: {:decoded, payload},
        priority: 2,
        path: identity.path,
        url: "https://example.test/binding"
      }

      assert %{route: :human_hold, evidence_code: ^expected_code} =
               FindingRouter.route(@contract, finding, @binding)
    end
  end

  test "scope-reference mismatch and malformed kind-specific fields fail closed" do
    # Mutations caught: accepting nearby Scope Contract references or incomplete ownership proof.
    cases = [
      {put_in(@same_pr_payload, ["scope_ref", "id"], "AC-99"), :scope_reference_mismatch},
      {put_in(@same_pr_payload, ["scope_ref"], %{"type" => "acceptance_criterion", "value" => "AC-2"}), :invalid_scope_reference},
      {%{
         "schema_version" => 1,
         "kind" => "introduced_by_pr",
         "binding" => @same_pr_payload["binding"],
         "proof" => %{"type" => "reviewer_opinion"}
       }, :invalid_current_pr_diff_proof},
      {%{
         "schema_version" => 1,
         "kind" => "follow_up",
         "binding" => @same_pr_payload["binding"],
         "relation" => "later"
       }, :invalid_follow_up_relation}
    ]

    for {payload, expected_code} <- cases do
      finding = %{
        thread_id: "thread-fields-#{expected_code}",
        finding_comment_id: "comment-fields-#{expected_code}",
        disposition_actor: @trusted_actor,
        disposition: {:decoded, payload},
        priority: 2,
        path: "lib/router.ex",
        url: "https://example.test/#{expected_code}"
      }

      assert %{route: :human_hold, evidence_code: ^expected_code} =
               FindingRouter.route(@contract, finding, @binding)
    end
  end

  test "valid metadata with an unknown nested key fails closed" do
    # Mutation caught: validating only top-level keys while accepting ambiguous nested schema additions.
    payload = put_in(@same_pr_payload, ["binding", "repository"], "owner/repo")

    finding = %{
      thread_id: "thread-nested-key",
      finding_comment_id: "comment-nested-key",
      disposition_actor: @trusted_actor,
      disposition: {:decoded, payload},
      priority: 2,
      path: "lib/router.ex",
      url: "https://example.test/nested-key"
    }

    assert %{route: :human_hold, evidence_code: :unknown_disposition_field} =
             FindingRouter.route(@contract, finding, @binding)
  end
end
