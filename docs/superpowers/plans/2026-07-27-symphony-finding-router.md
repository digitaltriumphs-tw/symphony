# Symphony Typed Finding Router Implementation Plan

> **For Codex:** Use `superpowers:test-driven-development` for every behavior change. Publishing and merge remain controller-owned.

**Goal:** Stop Symphony from returning an issue to `In Progress` merely because a P1-P4 finding exists; require trusted, machine-verifiable scope disposition first.

**Architecture:** Add one pure `FindingRouter` that consumes a parsed `ScopeContract`, a normalized review finding, and current PR binding evidence. GitHub review comments may carry one versioned JSON disposition block emitted by a trusted Codex reviewer; the block is parsed structurally with exact sentinels and `Jason`, never inferred from prose. Review convergence partitions findings into same-PR repair and held routes. ReviewMonitor moves state only for verified same-PR findings and deduplicates held-route comments by stable GitHub identity.

**Tech Stack:** Elixir 1.19, ExUnit, Jason, existing GitHub CLI adapter, existing ReviewConvergence and ReviewMonitor.

**Dependency:** This is stacked work on `aroakpm-svg/symphony` PR #8, exact base `d252f5c597aea49796b5c84b608251c89ec01a3e`. Do not publish it as an independent target-main PR until PR #8 merges; until then, publish only as an explicitly stacked fork PR.

**Constraints:**

- Severity P1-P4 indicates actionability, never scope ownership.
- No natural-language scope classification, filename inference, negative keyword list, or phrase regex.
- Accept disposition metadata only from the existing immutable trusted Codex reviewer identities and only when the block is in the selected finding comment.
- The normalized record attaches the actual GitHub `thread_id` and `finding_comment_id`; the emitter does not need to predict its GitHub-generated ID.
- Every disposition payload must bind exact current `base_sha`, `head_sha`, and finding `path`.
- Missing, duplicate, malformed, unknown, untrusted, stale, or mismatched metadata fails closed to `human_hold`.
- `same_pr` must match an existing Scope Contract AC ID or exact invariant value.
- `introduced_by_pr` must use `proof.type=current_pr_diff` and matching base/head/path.
- `prerequisite` must match an exact Scope Contract dependency.
- `follow_up` permits only `adjacent` or `pre_existing`.
- A same-PR partition may move the issue to `In Progress`; held partitions are commented separately and never included in the repair instruction.
- If no verified same-PR finding exists, keep the issue `In Review`, do not increment fix rounds, do not request another review, and do not move state.
- Keep readiness/branch freshness, clustering/review budgets, rulesets, merge, and metrics out of this PR.
- Remove the existing `structural_risk?` natural-language regex and its snapshot field; max fix-round escalation remains unchanged until the later convergence-budget PR.
- All production changes follow RED -> GREEN -> REFACTOR with receipts.

The exact hidden block is:

```text
<!-- symphony-finding-disposition:v1
{"schema_version":1,"kind":"same_pr","binding":{"base_sha":"<base>","head_sha":"<head>","path":"lib/example.ex"},"scope_ref":{"type":"acceptance_criterion","id":"AC-1"}}
-->
```

Supported kind-specific fields:

- `same_pr`: `scope_ref={type: acceptance_criterion, id: AC-N}` or `{type: invariant, value: exact_text}`.
- `introduced_by_pr`: `proof={type: current_pr_diff}`; common binding is the proof target.
- `prerequisite`: `scope_ref={type: dependency, value: exact_text}`.
- `follow_up`: `relation=adjacent|pre_existing`.
- `human_hold`: no additional ownership claim.

---

### Task 1: Add Scope Contract reference resolution and the pure Finding Router

**Files:**

- Modify: `elixir/lib/symphony_elixir/scope_contract.ex`
- Modify: `elixir/test/symphony_elixir/scope_contract_test.exs`
- Create: `elixir/lib/symphony_elixir/finding_router.ex`
- Create: `elixir/test/symphony_elixir/finding_router_test.exs`

**Step 1: Write failing reference and routing tests**

Add literal tests proving:

- AC ID, exact invariant, and exact dependency references resolve through a public typed ScopeContract API;
- nearby text, unknown IDs, and missing dependencies do not resolve;
- trusted valid `same_pr` and `introduced_by_pr` payloads route to `:same_pr` with evidence codes;
- trusted prerequisite and follow-up payloads route to their held routes;
- explicit human hold, missing disposition, untrusted actor, malformed/duplicate metadata, unknown kind/version/field, binding mismatch, and scope-reference mismatch route to `:human_hold` with stable codes;
- route records retain `thread_id`, `finding_comment_id`, priority/path/URL, original kind, and machine-verifiable evidence without using body text as identity.

Use independently authored maps and literal expected routes. Do not call private parser helpers or compute expectations with the router.

**Step 2: Verify RED**

Run from `elixir/`:

```bash
mise exec -- sh -lc 'mix test test/symphony_elixir/scope_contract_test.exs test/symphony_elixir/finding_router_test.exs'
```

Save expected missing-API failures.

**Step 3: Implement the minimal pure APIs**

- Add `ScopeContract.reference_exists?/2` for typed `{:acceptance_criterion, id}`, `{:invariant, exact_text}`, and `{:dependency, exact_text}` references, reusing the existing AC identifier parser.
- Add `SymphonyElixir.FindingRouter.route/3` with public types for route, reason/evidence code, and normalized routed record.
- Validate exact version, known keys, common binding, kind-specific fields, actor trust, and Scope Contract reference.
- Map `introduced_by_pr` to route `:same_pr` while preserving original kind and `:current_pr_diff_verified` evidence.
- Keep the module pure; no GitHub, Linear, file, environment, regex, or state I/O.

**Step 4: Verify GREEN and refactor**

Run focused tests, format, specs, and Credo. Perform mutation checks for wrong AC ID, stale SHA, wrong path, untrusted actor, unknown key, and severity-only routing.

**Step 5: Commit**

Commit only Task 1 files with a focused message such as `feat: add typed finding router`, and record RED/GREEN evidence.

---

### Task 2: Normalize trusted structured dispositions from GitHub review evidence

**Files:**

- Modify: `elixir/lib/symphony_elixir/github_review_client.ex`
- Modify: `elixir/test/symphony_elixir/review_convergence_test.exs`

**Step 1: Write failing adapter tests**

Add behavior tests proving:

- GraphQL review-thread comments retain thread ID, comment ID, author identity, body/path/URL/commit;
- exactly one sentinel block decodes JSON and is attached to that same finding comment;
- missing, duplicate, unterminated, invalid JSON, unknown version, and untrusted-author blocks produce typed normalization evidence rather than exceptions;
- prior-head unresolved P1-P4 findings remain normalized/actionable but stale binding is available for the router to hold;
- PR body is fetched and parsed exactly once into the snapshot Scope Contract result;
- `request_review` instructions describe the versioned block and do not claim severity implies ownership;
- the former structural-risk phrases no longer change snapshot or convergence evidence.

Test observable normalized output, not source text. Use complete GraphQL-like fixtures including actor identity and comment IDs.

**Step 2: Verify RED**

Run the focused GitHub adapter tests and save the expected missing-fields/old-structural-risk failures.

**Step 3: Implement structural normalization**

- Fetch PR `body`, thread `id`, comment `id`, and author login/type/database ID in both GraphQL queries.
- Delegate exact sentinel extraction and JSON normalization to `FindingRouter.extract_disposition/1`; do not duplicate its schema parser or inspect surrounding prose for ownership.
- Preserve the raw canonical GitHub actor identity on the selected finding; `FindingRouter` remains the trust authority.
- Attach actual `thread_id` and `finding_comment_id` from GitHub outside the JSON payload.
- Parse the PR body with `ScopeContract.parse_pr_body/1` and keep either typed contract or typed errors in the snapshot.
- Update review-request instructions so trusted Codex reviewers know the exact schema; missing metadata remains a safe hold.
- Remove `structural_risk?`, its test seam, phrase regex, and snapshot field.

**Step 4: Verify GREEN**

Run adapter/review tests, format, specs, Credo, and mutation checks for author, comment ID, duplicate sentinel, and stale binding.

**Step 5: Stage for the final integration commit**

Keep Task 2 changes in the single Tasks 2-4 integration package.

---

### Task 3: Route convergence decisions and state transitions by verified ownership

**Files:**

- Modify: `elixir/lib/symphony_elixir/review_convergence.ex`
- Modify: `elixir/lib/symphony_elixir/review_monitor.ex`
- Modify: `elixir/test/symphony_elixir/review_convergence_test.exs`

**Step 1: Write failing end-to-end policy tests**

Add tests proving:

- an unresolved P2 without trusted valid disposition returns `{:hold, ...}` and ReviewMonitor leaves the issue `In Review`;
- valid same-PR AC/invariant and introduced-by-PR evidence return `:rework`, comment only the same-PR partition, persist transition intent, move state, and increment one fix round;
- prerequisite/follow-up/human-hold-only sets publish one deduplicated route comment, do not move state, do not increment rounds, and do not request another review;
- mixed sets move only because of the same-PR partition and separately comment/deduplicate held findings; repair comments never instruct the worker to fix held findings;
- invalid Scope Contract or mismatched binding stays held;
- prior-head unresolved threads stay blocking/held until current binding exists;
- stable dedup keys sort tuples of `{thread_id, finding_comment_id, route, evidence_code}` and ignore wording edits;
- escalation counts only persisted same-PR rework transitions; held findings never trigger max-round escalation.

**Step 2: Verify RED**

Run focused convergence/monitor tests and save expected old `:rework`/state-transition failures.

**Step 3: Implement partitioned decisions**

- Extend the decision type with `{:hold, evidence}`.
- Route all actionable findings through FindingRouter using the single snapshot Scope Contract and base/head binding.
- If at least one same-PR route exists, return rework evidence with separate `same_pr_findings` and `held_findings`; otherwise return hold evidence.
- Remove structural-risk escalation; retain max-fix-round escalation only for same-PR routes.
- In ReviewMonitor, publish/deduplicate held-route comments by stable identity. For mixed decisions, persist the held comment before a same-PR transition.
- Rework comment, fingerprint, intent, and state transition use only same-PR routes.
- Hold-only decisions publish pending status and leave tracker state unchanged.

**Step 4: Verify GREEN and durability**

Run focused tests, format, specs, Credo. Confirm restart/dedup tests and pending transition recovery remain green.

**Step 5: Stage for the final integration commit**

Keep Task 3 changes in the single Tasks 2-4 integration package.

---

### Task 4: Document the disposition contract and run focused integration verification

**Files:**

- Modify: `SPEC.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`
- Add/commit: `docs/superpowers/plans/2026-07-27-symphony-finding-router.md`

**Step 1: Document boundaries**

Document the versioned block, trusted actor requirement, exact binding/reference rules, mixed-route behavior, fail-closed hold, stable dedup identity, and the fact that this PR does not add readiness, clustering/budgets, repository settings, or merge authority.

**Step 2: Run targeted verification**

From `elixir/` run:

```bash
mise exec -- sh -lc 'mix test test/symphony_elixir/scope_contract_test.exs test/symphony_elixir/finding_router_test.exs test/symphony_elixir/review_convergence_test.exs'
mise exec -- sh -lc 'mix format --check-formatted && mix specs.check && mix credo --strict'
```

**Step 3: Commit and handoff**

Commit Tasks 2-4 as one final integration package after focused tests, compile warnings, format,
specs, Credo, and diff inspection pass. Do not run the full coverage/Dialyzer gate or push from this
package; the controller owns whole-branch risk review and publishing.
