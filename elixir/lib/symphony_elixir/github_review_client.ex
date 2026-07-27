defmodule SymphonyElixir.GitHubReviewClient do
  @moduledoc "Reads latest-head review evidence and requests Codex reviews through `gh`."

  alias SymphonyElixir.{FindingRouter, ScopeContract}

  @graphql """
  query SymphonyReviewConvergence($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        number
        body
        headRefOid
        baseRefName
        baseRefOid
        reviews(last: 100) {
          nodes {
            body
            state
            submittedAt
            commit { oid }
            author {
              login
              __typename
              ... on Organization { databaseId }
              ... on Bot { databaseId }
            }
          }
        }
        reviewThreads(first: 100, after: $endCursor) {
          nodes {
            isResolved
            id
            comments(first: 100) {
              nodes {
                id
                body
                path
                url
                commit { oid }
                author {
                  login
                  __typename
                  ... on Organization { databaseId }
                  ... on Bot { databaseId }
                  ... on User { databaseId }
                }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @thread_comments_graphql """
  query SymphonyReviewThreadComments($threadId: ID!, $endCursor: String) {
    node(id: $threadId) {
      ... on PullRequestReviewThread {
        comments(first: 100, after: $endCursor) {
          nodes {
            id
            body
            path
            url
            commit { oid }
            author {
              login
              __typename
              ... on Organization { databaseId }
              ... on Bot { databaseId }
              ... on User { databaseId }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @trusted_reviewers [
    %{login: "chatgpt-codex-connector", type: "Organization", database_id: 261_883_814},
    %{login: "chatgpt-codex-connector", type: "Bot", database_id: 199_175_422},
    %{login: "chatgpt-codex-connector[bot]", type: "Bot", database_id: 199_175_422}
  ]
  @trusted_comment_app %{slug: "chatgpt-codex-connector", id: 1_144_995}
  @trusted_comment_user %{login: "chatgpt-codex-connector[bot]", type: "Bot", id: 199_175_422}
  @expected_checks [
    %{name: "make-all", app_slug: "github-actions", app_id: 15_368},
    %{name: "validate-pr-description", app_slug: "github-actions", app_id: 15_368}
  ]

  @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(repository, branch) when is_binary(repository) and is_binary(branch) do
    with {:ok, number} <- find_pull_request(repository, branch),
         {:ok, pull_request} <- fetch_pull_request(repository, number),
         {:ok, issue_comments} <- fetch_issue_comments(repository, number),
         {:ok, checks} <- required_checks(repository, pull_request),
         {:ok, base_verification} <- verify_base_claims(repository, pull_request) do
      {:ok,
       pull_request
       |> normalize_snapshot(checks, base_verification, issue_comments)
       |> Map.put(:repository, repository)
       |> Map.put(:pull_request_number, number)}
    end
  end

  @spec request_review(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def request_review(repository, number, key) do
    body = review_request_body(key)

    case run(["pr", "comment", Integer.to_string(number), "--repo", repository, "--body", body]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec review_request_exists?(String.t(), pos_integer(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def review_request_exists?(repository, number, key) do
    case run(["api", "--paginate", "--slurp", "repos/#{repository}/issues/#{number}/comments"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, pages} when is_list(pages) ->
            {:ok,
             pages
             |> List.flatten()
             |> Enum.any?(&String.contains?(&1["body"] || "", "dedup-key: `#{key}`"))}

          {:ok, unexpected} ->
            {:error, {:invalid_issue_comments, unexpected}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def publish_status(repository, head_sha, state, description, target_url \\ nil)
      when state in [:pending, :success, :failure, :error] do
    fields = [
      "state=#{state}",
      "context=Review Convergence Gate",
      "description=#{String.slice(description, 0, 140)}"
    ]

    fields = if is_binary(target_url), do: fields ++ ["target_url=#{target_url}"], else: fields
    args = ["api", "repos/#{repository}/statuses/#{head_sha}", "--method", "POST"] ++ Enum.flat_map(fields, &["-f", &1])

    case run(args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec normalize_no_required_checks_for_test(String.t()) :: {:ok, []} | {:error, term()}
  def normalize_no_required_checks_for_test(output), do: normalize_no_required_checks(output)

  @doc false
  @spec normalize_required_checks_for_test(String.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def normalize_required_checks_for_test(output, status), do: normalize_required_checks(output, status)

  @doc false
  @spec normalize_expected_checks_for_test(map()) :: {:ok, [map()]} | {:error, term()}
  def normalize_expected_checks_for_test(payload), do: normalize_expected_checks(payload)

  @doc false
  @spec merge_required_checks_for_test([map()], [map()]) :: [map()]
  def merge_required_checks_for_test(expected, protected), do: merge_required_checks(expected, protected)

  @doc false
  @spec merge_check_run_pages_for_test([map()]) :: {:ok, map()} | {:error, term()}
  def merge_check_run_pages_for_test(pages), do: merge_check_run_pages(pages)

  @doc false
  @spec normalize_required_contexts_for_test([map()], map() | nil) :: {:ok, [map()]} | {:error, term()}
  def normalize_required_contexts_for_test(rules, protection),
    do: normalize_required_contexts(rules, protection)

  @doc false
  @spec match_required_contexts_for_test([map()], map()) :: {:ok, [map()]} | {:error, term()}
  def match_required_contexts_for_test(contexts, payload),
    do: match_required_contexts(contexts, payload, [])

  @doc false
  @spec match_required_contexts_for_test([map()], map(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def match_required_contexts_for_test(contexts, payload, statuses),
    do: match_required_contexts(contexts, payload, statuses)

  @doc false
  @spec accepted_review_for_test?(map(), String.t()) :: boolean()
  def accepted_review_for_test?(review, head_sha), do: accepted_review?(review, head_sha)

  @doc false
  @spec latest_accepted_review_for_test([map()], String.t()) :: map() | nil
  def latest_accepted_review_for_test(reviews, head_sha),
    do: latest_accepted_review(reviews, head_sha)

  @doc false
  @spec accepted_comment_attestation_for_test([map()], String.t()) :: map() | nil
  def accepted_comment_attestation_for_test(comments, head_sha),
    do: accepted_comment_attestation(comments, head_sha)

  @doc false
  @spec merge_pull_request_pages_for_test([map()]) :: {:ok, map()} | {:error, term()}
  def merge_pull_request_pages_for_test(pages), do: merge_pull_request_pages(pages)

  @doc false
  @spec merge_thread_comment_pages_for_test([map()]) :: {:ok, [map()]} | {:error, term()}
  def merge_thread_comment_pages_for_test(pages), do: merge_thread_comment_pages(pages)

  @doc false
  @spec normalize_threads_for_test([map()], String.t()) :: [map()]
  def normalize_threads_for_test(threads, head_sha), do: normalize_threads(threads, head_sha)

  @doc false
  @spec normalize_snapshot_for_test(map(), [map()], map(), [map()]) :: map()
  def normalize_snapshot_for_test(pull_request, checks, base_verification, issue_comments),
    do: normalize_snapshot(pull_request, checks, base_verification, issue_comments)

  @doc false
  @spec review_request_body_for_test(String.t()) :: String.t()
  def review_request_body_for_test(key), do: review_request_body(key)

  @doc false
  @spec base_missing_paths_for_test([map()], String.t()) :: [String.t()]
  def base_missing_paths_for_test(threads, head_sha), do: base_missing_paths(threads, head_sha)

  @doc false
  @spec normalize_branch_protection_response_for_test(String.t(), integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def normalize_branch_protection_response_for_test(output, status),
    do: normalize_branch_protection_response(output, status)

  @doc false
  @spec pull_request_query_for_test() :: String.t()
  def pull_request_query_for_test, do: @graphql

  @doc false
  @spec missing_paths_verified_for_test?(MapSet.t(String.t()), [String.t()]) :: boolean()
  def missing_paths_verified_for_test?(base_paths, claimed_missing_paths) do
    missing_paths_verified?(base_paths, claimed_missing_paths)
  end

  @doc false
  @spec base_tree_oid_for_test(map()) :: {:ok, String.t()} | {:error, term()}
  def base_tree_oid_for_test(payload), do: base_tree_oid(payload)

  @doc false
  @spec encode_path_segment_for_test(String.t()) :: String.t()
  def encode_path_segment_for_test(value), do: encode_path_segment(value)

  defp review_request_body(key) do
    """
    @codex review

    For every actionable P1-P4 finding, append exactly one disposition block to that same finding comment. Severity P1-P4 indicates actionability, not scope ownership. Do not put disposition metadata in a separate comment and do not infer any field from prose.

    Use exactly one v1 shape, with the PR's exact base SHA, head SHA, and finding path:

    <!-- symphony-finding-disposition:v1
    {"schema_version":1,"kind":"same_pr","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"scope_ref":{"type":"acceptance_criterion","id":"AC-1"}}
    -->

    The only other exact payload shapes allowed between those same sentinel lines are:

    - `{"schema_version":1,"kind":"same_pr","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"scope_ref":{"type":"invariant","value":"<exact Scope Contract invariant>"}}`
    - `{"schema_version":1,"kind":"introduced_by_pr","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"proof":{"type":"current_pr_diff"}}`
    - `{"schema_version":1,"kind":"prerequisite","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"scope_ref":{"type":"dependency","value":"<exact Scope Contract dependency>"}}`
    - `{"schema_version":1,"kind":"follow_up","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"},"relation":"adjacent"}` or the same object with `"relation":"pre_existing"`.
    - `{"schema_version":1,"kind":"human_hold","binding":{"base_sha":"<base_sha>","head_sha":"<head_sha>","path":"<finding_path>"}}`

    Unknown, duplicate, missing, stale, or untrusted metadata fails closed to human hold.

    dedup-key: `#{key}`
    """
  end

  defp find_pull_request(repository, branch) do
    args = [
      "pr",
      "list",
      "--repo",
      repository,
      "--state",
      "open",
      "--head",
      branch,
      "--json",
      "number"
    ]

    with {:ok, output} <- run(args),
         {:ok, [%{"number" => number} | _]} <- Jason.decode(output) do
      {:ok, number}
    else
      {:ok, []} -> {:error, :pull_request_not_found}
      {:ok, unexpected} -> {:error, {:invalid_pull_request_lookup, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pull_request(repository, number) do
    [owner, name] = String.split(repository, "/", parts: 2)

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{@graphql}",
      "-F",
      "owner=#{owner}",
      "-F",
      "name=#{name}",
      "-F",
      "number=#{number}",
      "--paginate",
      "--slurp"
    ]

    with {:ok, output} <- run(args),
         {:ok, decoded} when is_list(decoded) <- Jason.decode(output),
         {:ok, pull_request} <- merge_pull_request_pages(decoded),
         {:ok, pull_request} <- hydrate_pull_request_threads(repository, pull_request) do
      {:ok, pull_request}
    else
      nil -> {:error, :pull_request_not_found}
      {:ok, unexpected} -> {:error, {:invalid_pull_request_payload, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_comments(repository, number) do
    case run(["api", "--paginate", "--slurp", "repos/#{repository}/issues/#{number}/comments?per_page=100"]) do
      {:ok, output} ->
        with {:ok, pages} when is_list(pages) <- Jason.decode(output),
             comments when is_list(comments) <- List.flatten(pages) do
          {:ok, comments}
        else
          unexpected -> {:error, {:invalid_issue_comments, unexpected}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_checks(repository, pull_request) do
    head_sha = pull_request["headRefOid"]

    with {:ok, output} <-
           run([
             "api",
             "--paginate",
             "--slurp",
             "repos/#{repository}/commits/#{head_sha}/check-runs?per_page=100",
             "-H",
             "Accept: application/vnd.github+json"
           ]),
         {:ok, pages} when is_list(pages) <- Jason.decode(output),
         {:ok, payload} <- merge_check_run_pages(pages),
         {:ok, statuses} <- commit_statuses(repository, head_sha),
         {:ok, expected} <- normalize_expected_checks(payload),
         {:ok, contexts} <- required_contexts(repository, pull_request["baseRefName"]),
         {:ok, protected} <- match_required_contexts(contexts, payload, statuses) do
      {:ok, merge_required_checks(expected, protected)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_statuses(repository, head_sha) do
    with {:ok, output} <-
           run([
             "api",
             "--paginate",
             "--slurp",
             "repos/#{repository}/commits/#{head_sha}/statuses?per_page=100"
           ]),
         {:ok, pages} when is_list(pages) <- Jason.decode(output),
         statuses when is_list(statuses) <- List.flatten(pages) do
      {:ok, statuses}
    else
      {:error, reason} -> {:error, reason}
      unexpected -> {:error, {:invalid_commit_statuses, unexpected}}
    end
  end

  defp required_contexts(repository, base_ref_name) when is_binary(base_ref_name) do
    with {:ok, rules_output} <-
           run([
             "api",
             "--paginate",
             "--slurp",
             "repos/#{repository}/rules/branches/#{encode_path_segment(base_ref_name)}?per_page=100"
           ]),
         {:ok, rule_pages} when is_list(rule_pages) <- Jason.decode(rules_output),
         rules when is_list(rules) <- List.flatten(rule_pages),
         {:ok, protection} <- branch_protection(repository, base_ref_name) do
      normalize_required_contexts(rules, protection)
    else
      {:error, reason} -> {:error, reason}
      unexpected -> {:error, {:invalid_required_rules, unexpected}}
    end
  end

  defp required_contexts(_repository, base_ref_name),
    do: {:error, {:invalid_base_ref_name, base_ref_name}}

  defp branch_protection(repository, base_ref_name) do
    {output, status} =
      run_with_status([
        "api",
        "repos/#{repository}/branches/#{encode_path_segment(base_ref_name)}/protection/required_status_checks"
      ])

    normalize_branch_protection_response(output, status)
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end

  defp normalize_branch_protection_response(output, status) do
    cond do
      status == 0 ->
        Jason.decode(output)

      status == 1 and
          (String.contains?(output, "Branch not protected") or
             String.contains?(output, "Required status checks are not enabled")) ->
        {:ok, nil}

      true ->
        {:error, {:required_status_checks_failed, status, String.trim(output)}}
    end
  end

  defp normalize_required_contexts(rules, protection) when is_list(rules) do
    contexts = ruleset_required_contexts(rules) ++ protection_required_contexts(protection)

    if invalid_required_contexts?(contexts) do
      {:error, {:invalid_required_contexts, contexts}}
    else
      {:ok, normalize_context_identities(contexts)}
    end
  end

  defp normalize_required_contexts(rules, protection),
    do: {:error, {:invalid_required_contexts, {rules, protection}}}

  defp ruleset_required_contexts(rules) do
    rules
    |> Enum.filter(&(&1["type"] == "required_status_checks"))
    |> Enum.flat_map(&(get_in(&1, ["parameters", "required_status_checks"]) || []))
  end

  defp protection_required_contexts(nil), do: []

  defp protection_required_contexts(protection) when is_map(protection),
    do: protection["checks"] || Enum.map(protection["contexts"] || [], &%{"context" => &1})

  defp protection_required_contexts(unexpected), do: [{:invalid, unexpected}]

  defp invalid_required_contexts?(contexts) do
    Enum.any?(contexts, fn
      %{"context" => context} -> not is_binary(context)
      _unexpected -> true
    end)
  end

  defp normalize_context_identities(contexts) do
    contexts
    |> Enum.reject(&(&1["context"] == "Review Convergence Gate"))
    |> Enum.map(&%{name: &1["context"], app_id: normalize_app_id(&1["integration_id"] || &1["app_id"])})
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.name, &1.app_id || 0})
  end

  defp normalize_app_id(-1), do: nil
  defp normalize_app_id(app_id), do: app_id

  defp match_required_contexts(contexts, %{"check_runs" => runs}, statuses)
       when is_list(contexts) and is_list(runs) and is_list(statuses) do
    {:ok,
     Enum.map(contexts, fn context ->
       required_context_evidence(context, runs, statuses)
     end)}
  end

  defp match_required_contexts(contexts, payload, statuses),
    do: {:error, {:invalid_required_context_evidence, {contexts, payload, statuses}}}

  defp required_context_evidence(context, runs, statuses) do
    matching_runs =
      Enum.filter(runs, fn run ->
        run["name"] == context.name and
          (is_nil(context.app_id) or get_in(run, ["app", "id"]) == context.app_id)
      end)

    run = latest_check_run(matching_runs)
    status = if is_nil(context.app_id), do: latest_commit_status(statuses, context.name)

    cond do
      run -> %{name: context.name, state: check_run_state(run), link: run["details_url"]}
      status -> %{name: context.name, state: normalize_check_state(status["state"]), link: status["target_url"]}
      true -> %{name: context.name, state: :missing, link: nil}
    end
  end

  defp latest_commit_status(statuses, context) do
    statuses
    |> Enum.filter(&(&1["context"] == context))
    |> Enum.max_by(&(&1["created_at"] || &1["updated_at"] || ""), fn -> nil end)
  end

  defp latest_check_run(runs) do
    Enum.max_by(
      runs,
      &(&1["completed_at"] || &1["started_at"] || &1["created_at"] || ""),
      fn -> nil end
    )
  end

  defp merge_required_checks(expected, protected) do
    (expected ++ protected)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, checks} ->
      %{
        name: name,
        state: checks |> Enum.map(& &1.state) |> Enum.max_by(&check_state_rank/1),
        link: Enum.find_value(checks, & &1.link)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp check_state_rank(:failure), do: 5
  defp check_state_rank(:missing), do: 4
  defp check_state_rank(:pending), do: 3
  defp check_state_rank(:neutral), do: 2
  defp check_state_rank(:skipped), do: 1
  defp check_state_rank(:success), do: 0
  defp check_state_rank(_state), do: 5

  defp normalize_expected_checks(%{"check_runs" => runs}) when is_list(runs) do
    checks =
      Enum.map(@expected_checks, fn expected ->
        run =
          runs
          |> Enum.filter(fn candidate ->
            candidate["name"] == expected.name and
              get_in(candidate, ["app", "slug"]) == expected.app_slug and
              get_in(candidate, ["app", "id"]) == expected.app_id
          end)
          |> latest_check_run()

        %{
          name: expected.name,
          state: check_run_state(run),
          link: run && run["details_url"]
        }
      end)

    {:ok, checks}
  end

  defp normalize_expected_checks(payload), do: {:error, {:invalid_check_runs, payload}}

  defp merge_check_run_pages(pages) when is_list(pages) do
    Enum.reduce_while(pages, {:ok, []}, fn
      %{"check_runs" => runs}, {:ok, acc} when is_list(runs) -> {:cont, {:ok, [runs | acc]}}
      payload, _acc -> {:halt, {:error, {:invalid_check_runs, payload}}}
    end)
    |> case do
      {:ok, pages_reversed} -> {:ok, %{"check_runs" => pages_reversed |> Enum.reverse() |> List.flatten()}}
      error -> error
    end
  end

  defp merge_check_run_pages(payload), do: {:error, {:invalid_check_run_pages, payload}}

  defp check_run_state(nil), do: :missing

  defp check_run_state(%{"status" => "completed", "conclusion" => conclusion}),
    do: normalize_check_state(conclusion)

  defp check_run_state(_run), do: :pending

  defp normalize_required_checks(output, status) do
    case Jason.decode(output) do
      {:ok, checks} when is_list(checks) ->
        {:ok,
         checks
         |> Enum.reject(&(&1["name"] == "Review Convergence Gate"))
         |> Enum.map(fn check ->
           %{
             name: check["name"],
             state: normalize_check_state(check["bucket"] || check["state"]),
             link: check["link"]
           }
         end)}

      {:error, _reason} when status == 1 ->
        normalize_no_required_checks(output)

      {:ok, unexpected} ->
        {:error, {:invalid_required_checks, unexpected}}

      {:error, reason} ->
        {:error, {:command_failed, status, reason}}
    end
  end

  defp merge_pull_request_pages(pages) when is_list(pages) and pages != [] do
    Enum.reduce_while(pages, {:ok, nil, []}, fn page, {:ok, first, threads} ->
      case validate_pull_request_page(page) do
        {:ok, pull_request, nodes} ->
          {:cont, {:ok, first || pull_request, [nodes | threads]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, first, pages_reversed} when is_map(first) ->
        {:ok,
         put_in(
           first,
           ["reviewThreads", "nodes"],
           pages_reversed |> Enum.reverse() |> List.flatten()
         )}

      error ->
        error
    end
  end

  defp merge_pull_request_pages(pages), do: {:error, {:invalid_pull_request_pages, pages}}

  defp validate_pull_request_page(
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" =>
                 %{
                   "reviewThreads" => %{
                     "nodes" => nodes,
                     "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
                   }
                 } = pull_request
             }
           }
         } = page
       ) do
    if is_list(nodes) and is_boolean(has_next_page) and
         (is_binary(end_cursor) or is_nil(end_cursor)) do
      {:ok, pull_request, nodes}
    else
      {:error, {:invalid_pull_request_page, page}}
    end
  end

  defp validate_pull_request_page(page), do: {:error, {:invalid_pull_request_page, page}}

  defp encode_path_segment(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp hydrate_pull_request_threads(repository, pull_request) do
    threads = get_in(pull_request, ["reviewThreads", "nodes"]) || []

    Enum.reduce_while(threads, {:ok, []}, fn thread, {:ok, acc} ->
      case hydrate_one_thread(repository, thread) do
        {:ok, hydrated} -> {:cont, {:ok, [hydrated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated_reversed} ->
        {:ok, put_in(pull_request, ["reviewThreads", "nodes"], Enum.reverse(hydrated_reversed))}

      error ->
        error
    end
  end

  defp hydrate_one_thread(repository, thread) do
    comments = get_in(thread, ["comments", "nodes"]) || []

    if length(comments) == 100 do
      fetch_all_thread_comments(repository, thread["id"])
      |> case do
        {:ok, comments} -> {:ok, put_in(thread, ["comments", "nodes"], comments)}
        error -> error
      end
    else
      {:ok, thread}
    end
  end

  defp fetch_all_thread_comments(_repository, thread_id) when is_binary(thread_id) do
    args = [
      "api",
      "graphql",
      "-f",
      "query=#{@thread_comments_graphql}",
      "-F",
      "threadId=#{thread_id}",
      "--paginate",
      "--slurp"
    ]

    with {:ok, output} <- run(args),
         {:ok, pages} when is_list(pages) <- Jason.decode(output),
         {:ok, comments} <- merge_thread_comment_pages(pages) do
      {:ok, comments}
    else
      {:ok, payload} -> {:error, {:invalid_thread_comment_pages, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_all_thread_comments(_repository, thread_id), do: {:error, {:missing_review_thread_id, thread_id}}

  defp merge_thread_comment_pages(pages) when is_list(pages) do
    Enum.reduce_while(pages, {:ok, []}, fn page, {:ok, acc} ->
      case get_in(page, ["data", "node", "comments", "nodes"]) do
        nodes when is_list(nodes) -> {:cont, {:ok, [nodes | acc]}}
        _ -> {:halt, {:error, {:invalid_thread_comment_page, page}}}
      end
    end)
    |> case do
      {:ok, pages_reversed} -> {:ok, pages_reversed |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp merge_thread_comment_pages(payload), do: {:error, {:invalid_thread_comment_pages, payload}}

  defp normalize_no_required_checks(output) do
    if output == "" or String.contains?(output, "checks reported on") do
      {:ok, []}
    else
      {:error, {:command_failed, 1, output}}
    end
  end

  defp verify_base_claims(repository, pull_request) do
    threads = get_in(pull_request, ["reviewThreads", "nodes"]) || []
    head_sha = pull_request["headRefOid"]
    paths = base_missing_paths(threads, head_sha)
    claim_present = base_missing_claim?(threads, head_sha)

    if claim_present do
      verify_claimed_base_paths(repository, pull_request["baseRefOid"], paths)
    else
      {:ok, %{required: false, result: :not_required}}
    end
  end

  defp verify_claimed_base_paths(_repository, _base_oid, []) do
    {:ok, %{required: true, result: :unverified}}
  end

  defp verify_claimed_base_paths(repository, base_oid, paths) do
    case fetch_base_tree_paths(repository, base_oid) do
      {:ok, base_paths} ->
        result = if missing_paths_verified?(base_paths, paths), do: :verified, else: :unverified
        {:ok, %{required: true, result: result}}

      {:error, _reason} ->
        {:ok, %{required: true, result: :unverified}}
    end
  end

  defp fetch_base_tree_paths(repository, base_oid) when is_binary(base_oid) do
    with {:ok, commit_output} <- run(["api", "repos/#{repository}/git/commits/#{base_oid}"]),
         {:ok, commit_payload} <- Jason.decode(commit_output),
         {:ok, tree_oid} <- base_tree_oid(commit_payload),
         {:ok, output} <- run(["api", "repos/#{repository}/git/trees/#{tree_oid}?recursive=1"]),
         {:ok, %{"tree" => tree, "truncated" => false}} when is_list(tree) <- Jason.decode(output) do
      {:ok, tree |> Enum.map(& &1["path"]) |> Enum.filter(&is_binary/1) |> MapSet.new()}
    else
      {:ok, payload} -> {:error, {:invalid_or_truncated_base_tree, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_base_tree_paths(_repository, base_oid), do: {:error, {:missing_base_oid, base_oid}}

  defp base_tree_oid(%{"tree" => %{"sha" => tree_oid}}) when is_binary(tree_oid) and tree_oid != "",
    do: {:ok, tree_oid}

  defp base_tree_oid(payload), do: {:error, {:missing_base_tree_oid, payload}}

  defp missing_paths_verified?(base_paths, claimed_missing_paths) do
    Enum.all?(claimed_missing_paths, &(not MapSet.member?(base_paths, &1)))
  end

  defp base_missing_paths(threads, head_sha) do
    threads
    |> current_head_comments(head_sha)
    |> Enum.flat_map(fn comment ->
      body = comment["body"] || ""

      if base_missing_claim_body?(body) do
        Regex.scan(~r/`([^`\r\n]+)`/, body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(&path_like?/1)
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp base_missing_claim?(threads, head_sha) do
    threads
    |> current_head_comments(head_sha)
    |> Enum.any?(fn comment -> base_missing_claim_body?(comment["body"] || "") end)
  end

  defp current_head_comments(threads, head_sha) do
    threads
    |> Enum.flat_map(fn thread -> get_in(thread, ["comments", "nodes"]) || [] end)
    |> Enum.filter(&(get_in(&1, ["commit", "oid"]) == head_sha))
  end

  defp base_missing_claim_body?(body) do
    Regex.match?(~r/base (?:branch|ref).*\b(?:missing|absent|does not (?:have|contain|exist))/i, body)
  end

  defp path_like?(value) do
    String.contains?(value, "/") and !String.contains?(value, " ")
  end

  defp normalize_snapshot(pull_request, checks, base_verification, issue_comments) do
    head_sha = pull_request["headRefOid"]
    threads = get_in(pull_request, ["reviewThreads", "nodes"]) || []
    reviews = get_in(pull_request, ["reviews", "nodes"]) || []
    trusted_current_head_reviews = trusted_current_head_reviews(reviews, head_sha)
    accepted_review = latest_accepted_review(reviews, head_sha)

    comment_attestation =
      if accepted_review || trusted_current_head_reviews != [],
        do: nil,
        else: accepted_comment_attestation(issue_comments, head_sha)

    reviewed_head_sha =
      if accepted_review || comment_attestation, do: head_sha, else: nil

    %{
      current_head_sha: head_sha,
      reviewed_head_sha: reviewed_head_sha,
      review_result: if(reviewed_head_sha, do: :no_major_issues, else: :missing),
      base_ref_oid: pull_request["baseRefOid"],
      base_verification_required: base_verification.required,
      base_verification: base_verification.result,
      scope_contract: ScopeContract.parse_pr_body(pull_request["body"] || ""),
      required_checks: checks,
      threads: normalize_threads(threads, head_sha)
    }
  end

  defp accepted_review?(review, head_sha) do
    get_in(review, ["commit", "oid"]) == head_sha and
      review["state"] in ["APPROVED", "COMMENTED"] and
      trusted_reviewer?(review["author"]) and
      String.contains?(review["body"] || "", "No major issues found")
  end

  defp latest_accepted_review(reviews, head_sha) do
    trusted_current_head = trusted_current_head_reviews(reviews, head_sha)

    with [_ | _] <- trusted_current_head,
         true <- Enum.all?(trusted_current_head, &valid_review_time?/1),
         latest <- Enum.max_by(trusted_current_head, & &1["submittedAt"]),
         true <- accepted_review?(latest, head_sha) do
      latest
    else
      _ -> nil
    end
  end

  defp trusted_current_head_reviews(reviews, head_sha) do
    Enum.filter(reviews, fn review ->
      get_in(review, ["commit", "oid"]) == head_sha and trusted_reviewer?(review["author"])
    end)
  end

  defp valid_review_time?(review) do
    match?({:ok, _, _}, DateTime.from_iso8601(review["submittedAt"] || ""))
  end

  defp accepted_comment_attestation(comments, head_sha)
       when is_list(comments) and is_binary(head_sha) do
    requests = Enum.filter(comments, &current_head_review_request?(&1, head_sha))

    with [request] <- requests,
         {:ok, request_time, _} <- DateTime.from_iso8601(request["created_at"] || ""),
         [attestation] <- trusted_responses(comments, request_time),
         true <- clean_comment_attestation?(attestation, head_sha, request_time) do
      attestation
    else
      _ -> nil
    end
  end

  defp accepted_comment_attestation(_comments, _head_sha), do: nil

  defp trusted_responses(comments, request_time) do
    comments
    |> Enum.filter(fn comment ->
      case DateTime.from_iso8601(comment["created_at"] || "") do
        {:ok, comment_time, _} ->
          trusted_comment_author?(comment) and DateTime.compare(comment_time, request_time) == :gt

        _ ->
          false
      end
    end)
    |> Enum.sort_by(& &1["created_at"])
  end

  defp current_head_review_request?(comment, head_sha) do
    body = comment["body"] || ""

    Regex.match?(~r/^@codex review(?:\r?\n|$)/, body) and
      String.contains?(body, "dedup-key:") and
      String.contains?(body, head_sha)
  end

  defp clean_comment_attestation?(comment, head_sha, request_time) do
    with {:ok, comment_time, _} <- DateTime.from_iso8601(comment["created_at"] || ""),
         true <- DateTime.compare(comment_time, request_time) == :gt,
         true <- trusted_comment_author?(comment),
         [reviewed_prefix] <- Regex.run(~r/\*\*Reviewed commit:\*\* `([0-9a-f]{10,40})`/i, comment["body"] || "", capture: :all_but_first) do
      String.starts_with?(head_sha, String.downcase(reviewed_prefix)) and
        Regex.match?(~r/^Codex Review: Didn't find any major issues\./, comment["body"] || "")
    else
      _ -> false
    end
  end

  defp trusted_comment_author?(comment) do
    user = comment["user"] || %{}
    app = comment["performed_via_github_app"] || %{}

    user["login"] == @trusted_comment_user.login and
      user["type"] == @trusted_comment_user.type and
      user["id"] == @trusted_comment_user.id and
      app["slug"] == @trusted_comment_app.slug and
      app["id"] == @trusted_comment_app.id
  end

  defp trusted_reviewer?(author) when is_map(author) do
    Enum.any?(@trusted_reviewers, fn reviewer ->
      author["login"] == reviewer.login and
        author["__typename"] == reviewer.type and
        author["databaseId"] == reviewer.database_id
    end)
  end

  defp trusted_reviewer?(_author), do: false

  defp normalize_threads(threads, _head_sha) do
    Enum.flat_map(threads, fn thread ->
      comment =
        (get_in(thread, ["comments", "nodes"]) || [])
        |> Enum.reverse()
        |> Enum.find(&(not is_nil(priority(&1["body"] || ""))))

      if comment do
        body = comment["body"] || ""

        [
          %{
            thread_id: thread["id"],
            finding_comment_id: comment["id"],
            disposition_actor: comment["author"],
            disposition: FindingRouter.extract_disposition(body),
            resolved: thread["isResolved"] == true,
            priority: priority(body),
            body: body,
            path: comment["path"],
            url: comment["url"],
            commit_sha: get_in(comment, ["commit", "oid"])
          }
        ]
      else
        []
      end
    end)
  end

  defp priority(body) do
    case Regex.run(~r/\bP([1-4])\b/i, body, capture: :all_but_first) do
      [priority] -> String.to_integer(priority)
      _ -> nil
    end
  end

  defp normalize_check_state(value) when is_binary(value) do
    case String.downcase(value) do
      state when state in ["pass", "success"] -> :success
      state when state in ["skipped", "skipping"] -> :skipped
      "neutral" -> :neutral
      "pending" -> :pending
      _ -> :failure
    end
  end

  defp normalize_check_state(_value), do: :failure

  defp run(args) do
    case run_with_status(args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end

  defp run_with_status(args), do: System.cmd("gh", args, stderr_to_stdout: true)
end
