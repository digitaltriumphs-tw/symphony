---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  project_slug: "central-brain-7ccfadd2fa3c"
  active_states:
    - "Todo"
    - "In Progress"
  terminal_states:
    - "Done"
    - "Canceled"
    - "Cancelled"
    - "Duplicate"
workspace:
  root: "C:/Users/aroak/Desktop/codex/symphony-workspaces"
hooks:
  after_create: |
    ENV_FILE="C:/Users/aroak/Desktop/codex/symphony/elixir/.env.local"
    if [ ! -f "$ENV_FILE" ] && [ -f "${ENV_FILE}.txt" ]; then
      ENV_FILE="${ENV_FILE}.txt"
    fi
    if [ -f "$ENV_FILE" ]; then
      set -a
      . "$ENV_FILE"
      set +a
    fi
    : "${SOURCE_REPO_URL:=https://github.com/aroakpm-svg/aroak-central-brain.git}"
    : "${SOURCE_REPO_DEFAULT_BRANCH:=}"
    if [ -n "$SOURCE_REPO_DEFAULT_BRANCH" ]; then
      git clone --branch "$SOURCE_REPO_DEFAULT_BRANCH" "$SOURCE_REPO_URL" .
    else
      git clone "$SOURCE_REPO_URL" .
    fi
    git checkout -b "codex/init-$(date +%s)"
agent:
  max_concurrent_agents: 2
  max_turns: 5
review_convergence:
  enabled: true
  repository: "aroakpm-svg/aroak-central-brain"
  review_state: "In Review"
  in_progress_state: "In Progress"
  max_fix_rounds: 3
  human_owner: "PM AROAK"
merge_authorization:
  enabled: false
  method: "squash"
codex:
  command: |
    ENV_FILE="C:/Users/aroak/Desktop/codex/symphony/elixir/.env.local"
    if [ ! -f "$ENV_FILE" ] && [ -f "${ENV_FILE}.txt" ]; then
      ENV_FILE="${ENV_FILE}.txt"
    fi
    if [ -f "$ENV_FILE" ]; then
      set -a
      . "$ENV_FILE"
      set +a
    fi
    : "${CLAUDE_BIN:=/c/Users/aroak/AppData/Local/Microsoft/WinGet/Packages/Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe/claude.exe}"
    if [ -x "$CLAUDE_BIN" ]; then
      export PATH="$(dirname "$CLAUDE_BIN"):$PATH"
    fi
    : "${CODEX_BIN:=/c/Users/aroak/.codex/plugins/.plugin-appserver/codex.exe}"
    : "${LINEAR_API_KEY:?Set LINEAR_API_KEY with permission to read issues, create comments, and update issue status}"
    : "${SOURCE_REPO_URL:=https://github.com/aroakpm-svg/aroak-central-brain.git}"
    ISSUE_IDENTIFIER="{{ issue.identifier }}"
    DEFAULT_CODEX_MODEL="${CODEX_DEFAULT_MODEL:-gpt-5.4-mini}"
    SELECTED_CODEX_MODEL="$DEFAULT_CODEX_MODEL"
    MODEL_SOURCE="workflow default"
    MODEL_LABELS=""
    BODY_MODEL_HINTS=""
    if [ -n "$LINEAR_API_KEY" ] && [ -n "$ISSUE_IDENTIFIER" ] && ! printf '%s' "$ISSUE_IDENTIFIER" | grep -q '{{'; then
      if MODEL_ROUTING_RESULT="$(ISSUE_IDENTIFIER="$ISSUE_IDENTIFIER" DEFAULT_CODEX_MODEL="$DEFAULT_CODEX_MODEL" LINEAR_API_KEY="$LINEAR_API_KEY" python - <<'PY'
    import json
    import os
    import re
    import sys
    import urllib.request

    api_key = os.environ["LINEAR_API_KEY"]
    issue_identifier = os.environ["ISSUE_IDENTIFIER"]
    default_model = os.environ["DEFAULT_CODEX_MODEL"]
    endpoint = "https://api.linear.app/graphql"
    supported = {
        "model:gpt-5.4-mini": "gpt-5.4-mini",
        "model:gpt-5.4": "gpt-5.4",
        "model:gpt-5.5": "gpt-5.5",
    }

    def linear_request(query, variables):
        payload = json.dumps({"query": query, "variables": variables}).encode("utf-8")
        request = urllib.request.Request(
            endpoint,
            data=payload,
            headers={
                "Authorization": api_key,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            body = json.loads(response.read().decode("utf-8"))
        if body.get("errors"):
            raise RuntimeError(body["errors"])
        return body["data"]

    issue_query = """
    query Issue($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        description
        labels { nodes { name } }
      }
    }
    """

    data = linear_request(issue_query, {"id": issue_identifier})
    issue = data.get("issue")
    if not issue:
        print(f"error=Linear issue {issue_identifier} was not found")
        sys.exit(1)

    labels = [node["name"] for node in issue["labels"]["nodes"]]
    model_labels = [label for label in labels if label in supported]
    description = issue.get("description") or ""
    body_hints = sorted(set(re.findall(r"model:gpt-5\.(?:4-mini|4|5)|gpt-5\.(?:4-mini|4|5)", description)))

    if len(model_labels) > 1:
        comment = (
            "Blocked before Codex dispatch: multiple Codex model labels are set on this issue.\n\n"
            f"Detected labels: {', '.join(model_labels)}\n\n"
            "Please keep exactly one of these labels before retrying:\n"
            "- `model:gpt-5.4-mini`\n"
            "- `model:gpt-5.4`\n"
            "- `model:gpt-5.5`\n\n"
            "I did not start Codex Agent, to avoid wasting tokens on an ambiguous model selection."
        )
        mutation = """
        mutation CommentCreate($issueId: String!, $body: String!) {
          commentCreate(input: { issueId: $issueId, body: $body }) {
            success
          }
        }
        """
        linear_request(mutation, {"issueId": issue["id"], "body": comment})
        print("conflict=multiple-model-labels")
        print("model_labels=" + ",".join(model_labels))
        sys.exit(0)

    if model_labels:
        selected = supported[model_labels[0]]
        source = f"Linear label {model_labels[0]}"
    else:
        selected = default_model
        source = "workflow default"

    print("model=" + selected)
    print("source=" + source)
    print("model_labels=" + ",".join(model_labels))
    print("body_model_hints=" + ",".join(body_hints))
    PY
    )"; then
        :
      else
        ROUTING_STATUS="$?"
        echo "Blocked before Codex dispatch because model routing failed with exit status $ROUTING_STATUS." >&2
        printf '%s\n' "$MODEL_ROUTING_RESULT" >&2
        exit "$ROUTING_STATUS"
      fi
      ROUTING_CONFLICT="$(printf '%s\n' "$MODEL_ROUTING_RESULT" | sed -n 's/^conflict=//p' | tail -n 1)"
      if [ -n "$ROUTING_CONFLICT" ]; then
        echo "Blocked before Codex dispatch because model routing reported: $ROUTING_CONFLICT" >&2
        printf '%s\n' "$MODEL_ROUTING_RESULT" >&2
        exit 1
      fi
      ROUTED_MODEL="$(printf '%s\n' "$MODEL_ROUTING_RESULT" | sed -n 's/^model=//p' | tail -n 1)"
      ROUTED_SOURCE="$(printf '%s\n' "$MODEL_ROUTING_RESULT" | sed -n 's/^source=//p' | tail -n 1)"
      MODEL_LABELS="$(printf '%s\n' "$MODEL_ROUTING_RESULT" | sed -n 's/^model_labels=//p' | tail -n 1)"
      BODY_MODEL_HINTS="$(printf '%s\n' "$MODEL_ROUTING_RESULT" | sed -n 's/^body_model_hints=//p' | tail -n 1)"
      if [ -n "$ROUTED_MODEL" ]; then
        SELECTED_CODEX_MODEL="$ROUTED_MODEL"
        MODEL_SOURCE="$ROUTED_SOURCE"
      fi
      if [ -n "$MODEL_LABELS" ] && [ -n "$BODY_MODEL_HINTS" ]; then
        echo "WARNING: Linear model label overrides issue body model hints: labels=$MODEL_LABELS body=$BODY_MODEL_HINTS selected=$SELECTED_CODEX_MODEL" >&2
      fi
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "WARNING: GitHub CLI gh is unavailable; PR creation and PR updates may be skipped." >&2
    elif ! gh auth status >/dev/null 2>&1 && [ -z "${GITHUB_TOKEN:-}" ]; then
      echo "WARNING: GitHub CLI is not authenticated and GITHUB_TOKEN is unset; PR creation and PR updates may be skipped." >&2
    fi
    export CODEX_MODEL="$SELECTED_CODEX_MODEL"
    echo "Using Codex model: $CODEX_MODEL ($MODEL_SOURCE)" >&2
    exec "$CODEX_BIN" --config shell_environment_policy.inherit=all --model "$CODEX_MODEL" app-server
  approval_policy: "never"
  thread_sandbox: "workspace-write"
  turn_sandbox_policy:
    type: "workspaceWrite"
    writableRoots:
      - "C:/Users/aroak/Desktop/codex/symphony-workspaces"
    readOnlyAccess:
      type: "fullAccess"
    networkAccess: true
    excludeTmpdirEnvVar: false
    excludeSlashTmp: false
server:
  port: 4000
---

AROAK Central Brain Symphony Workflow

You are working on a Linear issue for the AROAK central-brain implementation project.

Your job is to turn one Linear issue into one small, reviewable GitHub PR, then leave a clear handoff in Linear and GitHub.

Current Linear Issue

Identifier: {{ issue.identifier }}

Title: {{ issue.title }}

State: {{ issue.state }}

URL: {{ issue.url }}

Branch: {{ issue.branch_name }}

{{ issue.description }}

Operating Principle

Move fast, but do not hide risk.

Prefer the smallest useful change that solves the root problem. Do not add broad rewrites, new infrastructure, or one-off special cases unless the issue explicitly asks for them.

Source Of Truth

Read these first:

This Linear issue title, description, comments, and acceptance criteria.

The latest Linear issue comments before editing files. If the issue description and latest comments conflict, follow the latest comments and explicitly state the conflict and chosen source in the Linear handoff.

The repository AGENTS.md, CLAUDE.md, README.md, or equivalent agent instructions if present.

The latest remote default branch code state. Fetch the remote before implementation, prefer origin/main, and if the repository default branch is not main use the actual default branch.

Existing source code and tests from a feature branch created from the latest fetched base branch, not from a stale checkout or old issue branch.

Current GitHub PRs related to this issue.

If these sources conflict, stop and leave a short Linear comment naming the conflict.

Codex Model Routing

Before Codex Agent dispatch, Symphony must resolve the model centrally in codex.command.

Supported Linear model labels:

model:gpt-5.4-mini

model:gpt-5.4

model:gpt-5.5

Default model: gpt-5.4-mini, unless CODEX_DEFAULT_MODEL is set in the local workflow environment.

If exactly one supported model label is present, that label wins.

If no supported model label is present, use the workflow default model.

If more than one supported model label is present, do not guess. Leave one blocker comment on the Linear issue and stop before starting Codex Agent.

If the issue body mentions a different model than the Linear label, the Linear label wins because labels are the machine-readable source. Report the conflict in stderr and include the chosen model in handoff.

Required Runtime Permissions

The runtime must provide:

LINEAR_API_KEY with permission to read issues, create comments, and update issue status.

GitHub authentication through gh auth login or GITHUB_TOKEN.

GitHub permission to create branches, push commits, open PRs, update PR descriptions, and comment on PRs.

Network access to Linear, GitHub, package registries, and public documentation needed for the issue.

The agent must not print, paste, commit, or expose token values.

If Linear or GitHub write access is missing, stop and leave the smallest actionable blocker in the final handoff.

Startup Preflight

Before editing files or moving the issue forward:

Read the latest Linear issue comments.

Fetch the latest remote refs.

Check the latest remote main or default branch SHA. Prefer origin/main; if the repository default branch is not main, use the actual default branch.

Record that SHA in your Linear comment, PR body, or final handoff.

Create or reset the issue feature branch from the latest fetched base branch before editing files.

Search for an existing GitHub PR by issue identifier, issue URL, and branch name.

If an existing PR already matches this issue, reuse it. Do not create a duplicate PR.

If the issue is already fixed on current main, do not code. Comment with the evidence and leave the issue in the correct state.

If required secrets, repo access, package install access, or GitHub/Linear auth are missing, follow the Fail Fast Blocker Rules and stop.

Fail Fast Blocker Rules

External blockers include: repository has no base commit or default branch, SOURCE_REPO_URL is missing or wrong, GitHub auth is missing, remote base SHA cannot be obtained, package install access is missing, Linear auth is missing, or the Linear issue lacks clear scope or acceptance criteria.

Before leaving a blocker comment, read the latest Linear comments.

If the same blocker already exists in the latest comments and you have no new evidence, do not add another comment. Stop.

If the same blocker appears twice consecutively, treat the issue as blocked and stop instead of continuing more turns.

Leave at most one blocker comment per distinct blocker. The comment must include what was checked, whether the repo has a base commit/default branch, whether GitHub auth is available, the concrete blocking reason, and the smallest human next step.

If Symphony or the runtime provides a blocked or stop mechanism, use it. Do not keep retrying or leave repeated preflight comments that only restate the same blocker.

Linear State Rules

Todo: ready for agent work. Move it to In Progress before coding.

In Progress: implementation is active.

In Review: PR is open, validation has been run, and human review is needed.

Done: terminal. Do not modify.

Canceled, Cancelled, Duplicate: terminal. Do not modify.

The agent may only move issues along this path:

Todo -> In Progress -> In Review

Do not mark an issue Done. Human reviewers own final acceptance and merge decisions.

If a PR receives human review feedback, the reviewer should move the Linear issue from In Review back to In Progress. The agent may then fix only the requested scope, rerun validation, update the same PR, and return the issue to In Review.

Allowed Autonomous Work

The agent is allowed to do the following without asking for extra approval:

Read code, docs, Linear issues, GitHub PRs, and CI logs.

Move the Linear issue from Todo to In Progress before implementation.

Implement scoped code changes.

Add or update tests.

Run local validation.

Create one GitHub branch and open one GitHub PR for the issue.

Update the existing GitHub PR if one already exists.

Leave Linear comments with status, blockers, validation results, and PR links.

Move the Linear issue to In Review when the PR is ready for human review.

Fix review feedback that stays within the issue scope.

Hard Stops

Do not do any of these unless the Linear issue explicitly says so and a human owner has approved it in the current issue thread:

Merge PRs.

Mark Linear issues Done.

Deploy to production.

Change production data.

Run database migrations against production.

Enable customer-facing feature flags.

Send live customer messages, emails, or notifications.

Touch billing, payment, auth, secrets, or permissions beyond the stated issue scope.

Make broad refactors unrelated to the issue.

If you hit a hard stop, leave a blocker comment and stop.

Implementation Rules

Keep the PR small.

Use existing code patterns before adding new abstractions. If you add a new module, helper, script, or workflow, explain why existing code could not be reused.

If you find unrelated cleanup, create or suggest a follow-up issue instead of expanding this PR.

Validation

Run the narrowest checks that prove the change.

Default validation:

npm test

npm run lint

npm run build

If the repository uses different commands, inspect package.json, README, CI config, or project docs and use the repo actual checks.

If a check cannot run, say exactly why and what human action is needed.

Review Feedback Intake

Pull-Request Scope Contract

Every PR description must use the repository's structured Scope Contract when the PR-body lint
applies; migrate an existing PR description before expecting that lint to pass. The contract is a
static boundary only: it does not classify findings or move issues in this change. Severity and
scope ownership are separate, so do not treat finding severity as proof that the current PR owns
the work.

Review routing consumes the typed contract separately from static lint. Every actionable finding
must put exactly one `symphony-finding-disposition:v1` metadata block on that same GitHub finding
comment. The trusted immutable actor, exact base SHA, head SHA, path, allowed fields, and exact
Scope Contract reference or kind-specific proof must verify. Severity never supplies ownership.
Missing, malformed, duplicate, untrusted, stale, or unknown evidence fails closed and keeps the
issue In Review.

Review Convergence Runtime

After a PR enters In Review, Symphony's Review Monitor owns machine-verifiable convergence. A
technical pass requires the exact latest head to have a clean review result, all required checks
passing, and zero unresolved actionable P1-P4 threads. A formal `PullRequestReview` is preferred.
Because Codex may emit its clean result as an issue comment, the runtime accepts that compatibility
shape only when there is exactly one persisted request bound to the full current head, the response
comes later from the allowlisted Codex App and bot database identities, and its explicit reviewed
commit matches the current head. Ordinary comments, display names, emoji, old heads, missing or
conflicting evidence never count. A new head invalidates the prior result and triggers one
deduplicated `@codex review` request.

The runtime publishes `Review Convergence Gate` as a commit status for ruleset enforcement. That
status is an output of the gate and is excluded from its prerequisite required-check set.

Only verified same-PR P1-P4 findings move the issue back to In Progress and reuse the same branch
and PR. Hold-only findings stay In Review without another review, state change, or fix round. For a
mixed result, the held findings are persisted separately before the same-PR transition. Both hold
and rework dedup use sorted `{thread_id, finding_comment_id, route, evidence_code}` identities, not
mutable prose. The retry limit applies only to same-PR transitions. Waiting for staging,
permissions, or human product/safety decisions keeps the issue In Review and pauses retries.
Technical convergence never authorizes merge, deployment, production changes, permission changes,
or Done.

For convergence budgeting, the verified PR2 `same_pr_findings` records are the only clustering
source. Canonical cluster IDs use exactly a typed acceptance-criterion reference, exact invariant,
or verified current-PR-diff path; prose, priority, URLs, display filenames, and regexes are ignored.
The versioned JSON ledger records `rework_intent`, `rework_completed`, and `convergence_hold` with
sorted cluster IDs and restores completed/pending operations and holds after restart.

A repeated cluster on the same exact head holds the whole issue, even when mixed with new clusters.
The existing `max_fix_rounds` limit, unclusterable evidence, malformed/contradictory ledger history,
or legacy rework without a typed manifest also creates Convergence Hold. One deduplicated team human
decision is left while the issue stays In Review; Symphony does not update issue state or request a
review. Hold-only PR2 routes consume no budget. This extension adds no new config, readiness logic,
ruleset/merge authority, cross-PR clustering, automatic human override, or metrics.

The state move is a recoverable transition, not two best-effort writes. Review Monitor first
persists a stable operation intent in Linear, then moves the issue, then persists a completion
marker. It resumes incomplete operations while the issue is in either In Review or In Progress,
re-reads durable history after restart, and counts exactly one fix round only after the target state
is observed and the matching typed cluster manifest is durably completed. Crash recovery reuses the
same operation ID and cluster IDs. Unknown responses, malformed history, or conflicting evidence
fail closed and never consume a round.

Authorized Merge Runtime

`merge_authorization.enabled` is separate from Review Convergence and defaults to false in this
workflow. If the team explicitly enables it, the runtime requires a durable exact release with no
Convergence Hold plus read-only GitHub evidence that the target branch requires both
`Review Convergence Gate` and strict branch-up-to-date checks. It never creates or changes a
ruleset. Before GitHub is called it persists one merge intent bound to repository, PR number, base
SHA, head SHA, method, and operation id; the request includes the expected head SHA. Completion or
typed failure is persisted separately, and restart recovery re-reads open/merged state so it never
sends a second merge for an already-merged PR. Head/base movement, conflict, permission failure,
rate limit, or missing ruleset evidence keeps the issue In Review. This path does not move Linear to
Done and does not authorize deployment, production writes, permission changes, admin bypass, force
merge, or merge queue.

Before returning the issue to In Review, read:

Linear issue comments.

GitHub PR comments.

GitHub inline review threads.

CI failure messages.

For each actionable feedback item, respond with one outcome:

Fixed, with file or commit reference.

Deferred, with reason or follow-up issue.

Rejected, with concise technical rationale.

Do not say the PR is ready while actionable feedback is still unanswered.

Required PR Body

Every PR must include:

Scope summary.

Files changed.

Validation run.

Safety gates respected.

Remaining risks or blockers.

Linear issue link.

Final Handoff

When finished:

Make sure the PR is linked in Linear.

Leave a Linear comment with:

PR URL.

Latest remote base SHA checked.

Validation commands and result.

Anything requiring human review.

Move the issue to In Review after the PR is open and validation has been run.

Stop. Human reviewers decide merge and final acceptance.
