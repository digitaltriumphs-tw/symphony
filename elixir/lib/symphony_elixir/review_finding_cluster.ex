defmodule SymphonyElixir.ReviewFindingCluster do
  @moduledoc """
  Canonical clustering for verified same-PR review findings.

  `FindingRouter` typed evidence is the only input authority. Mutable prose, priority, URLs, and
  display paths never participate in cluster identity.
  """

  @cluster_version 1
  @cluster_id_prefix "symphony-review-finding-cluster:v1:"

  @type cluster_key ::
          {:scope_reference, :acceptance_criterion, String.t()}
          | {:scope_reference, :invariant, String.t()}
          | {:current_pr_diff, String.t()}

  @type cluster :: %{
          required(:cluster_id) => String.t(),
          required(:key) => cluster_key(),
          required(:finding_count) => pos_integer()
        }

  @type cluster_error ::
          :not_verified_same_pr
          | :unsupported_evidence_code
          | :missing_scope_reference
          | :invalid_scope_reference
          | :missing_current_pr_diff_path
          | :invalid_current_pr_diff_proof
          | :invalid_findings

  @spec cluster([map()]) ::
          {:ok, [cluster()]}
          | {:error, {:unclusterable_finding, non_neg_integer(), cluster_error()}}
          | {:error, :invalid_findings}
  def cluster(findings) when is_list(findings) do
    findings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, &collect_cluster/2)
    |> case do
      {:ok, grouped} -> {:ok, canonical_clusters(grouped)}
      {:error, _reason} = error -> error
    end
  end

  def cluster(_findings), do: {:error, :invalid_findings}

  defp collect_cluster({finding, index}, {:ok, grouped}) do
    case cluster_key(finding) do
      {:ok, key} -> {:cont, {:ok, Map.update(grouped, key, 1, &(&1 + 1))}}
      {:error, reason} -> {:halt, {:error, {:unclusterable_finding, index, reason}}}
    end
  end

  defp cluster_key(%{route: :same_pr, evidence_code: :scope_contract_reference_verified} = finding) do
    scope_reference_key(get_in(finding, [:evidence, :scope_reference]))
  end

  defp cluster_key(%{route: :same_pr, evidence_code: :current_pr_diff_verified} = finding) do
    evidence = finding[:evidence]

    cond do
      not is_map(evidence) or evidence[:proof] != :current_pr_diff ->
        {:error, :invalid_current_pr_diff_proof}

      not is_map(evidence[:binding]) or not nonblank?(evidence[:binding][:path]) ->
        {:error, :missing_current_pr_diff_path}

      true ->
        {:ok, {:current_pr_diff, evidence[:binding][:path]}}
    end
  end

  defp cluster_key(%{route: :same_pr}), do: {:error, :unsupported_evidence_code}
  defp cluster_key(_finding), do: {:error, :not_verified_same_pr}

  defp scope_reference_key(nil), do: {:error, :missing_scope_reference}

  defp scope_reference_key({:acceptance_criterion, identifier}) do
    if nonblank?(identifier),
      do: {:ok, {:scope_reference, :acceptance_criterion, identifier}},
      else: {:error, :invalid_scope_reference}
  end

  defp scope_reference_key({:invariant, value}) do
    if nonblank?(value),
      do: {:ok, {:scope_reference, :invariant, value}},
      else: {:error, :invalid_scope_reference}
  end

  defp scope_reference_key(_reference), do: {:error, :invalid_scope_reference}

  defp canonical_clusters(grouped) do
    grouped
    |> Enum.map(fn {key, finding_count} ->
      %{cluster_id: cluster_id(key), key: key, finding_count: finding_count}
    end)
    |> Enum.sort_by(& &1.cluster_id)
  end

  defp cluster_id(key) do
    canonical = Jason.encode!([@cluster_version | Tuple.to_list(key)])
    digest = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    @cluster_id_prefix <> digest
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
