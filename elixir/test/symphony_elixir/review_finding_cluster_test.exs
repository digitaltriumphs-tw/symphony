defmodule SymphonyElixir.ReviewFindingClusterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewFindingCluster

  @ac_1_id "symphony-review-finding-cluster:v1:992112030cba4e48b120c7f3add9d5af9a895d323af521366122dc2f824bec84"
  @invariant_id "symphony-review-finding-cluster:v1:ececaf5eaa388c3875f8e48d795e2fecbe7901ed0c9015c3ecde19c22c472504"
  @current_diff_id "symphony-review-finding-cluster:v1:506b3e7fedceec635a36c148ae36dfa839a445ffda1a32ecc3cc4f86a81189ba"

  test "clusters verified same-PR records only from typed scope and current-diff evidence" do
    findings = [
      scope_finding({:invariant, "Preserve tenant boundaries."}),
      current_diff_finding("lib/current.ex"),
      scope_finding({:acceptance_criterion, "AC-1"}),
      scope_finding({:acceptance_criterion, "AC-1"}, %{body: "rewritten", priority: 4})
    ]

    assert {:ok, clusters} = ReviewFindingCluster.cluster(findings)

    assert clusters == [
             %{
               cluster_id: @current_diff_id,
               key: {:current_pr_diff, "lib/current.ex"},
               finding_count: 1
             },
             %{
               cluster_id: @ac_1_id,
               key: {:scope_reference, :acceptance_criterion, "AC-1"},
               finding_count: 2
             },
             %{
               cluster_id: @invariant_id,
               key: {:scope_reference, :invariant, "Preserve tenant boundaries."},
               finding_count: 1
             }
           ]
  end

  test "mutable finding prose, priority, URL, and display path cannot change a scope cluster" do
    first =
      scope_finding(
        {:acceptance_criterion, "AC-1"},
        %{body: "P1 original", priority: 1, url: "https://one.test", path: "lib/one.ex"}
      )

    rewritten =
      scope_finding(
        {:acceptance_criterion, "AC-1"},
        %{body: "P4 rewritten", priority: 4, url: "https://two.test", path: "lib/two.ex"}
      )

    assert {:ok, [%{cluster_id: @ac_1_id}]} = ReviewFindingCluster.cluster([first])
    assert {:ok, [%{cluster_id: @ac_1_id}]} = ReviewFindingCluster.cluster([rewritten])
  end

  test "current-PR diff clustering uses the verified binding path rather than display fields" do
    finding =
      current_diff_finding("lib/current.ex", %{
        body: "untrusted prose path lib/other.ex",
        path: "lib/display-only.ex",
        url: "https://example.test/files/other.ex"
      })

    assert {:ok,
            [
              %{
                cluster_id: @current_diff_id,
                key: {:current_pr_diff, "lib/current.ex"}
              }
            ]} = ReviewFindingCluster.cluster([finding])
  end

  test "unverified routes and malformed typed evidence fail closed instead of being inferred" do
    cases = [
      {%{scope_finding({:acceptance_criterion, "AC-1"}) | route: :human_hold}, :not_verified_same_pr},
      {%{scope_finding({:acceptance_criterion, "AC-1"}) | evidence_code: :missing_disposition}, :unsupported_evidence_code},
      {%{scope_finding({:acceptance_criterion, "AC-1"}) | evidence: %{}}, :missing_scope_reference},
      {scope_finding({:unsupported_reference, "AC-1"}), :invalid_scope_reference},
      {%{current_diff_finding("lib/current.ex") | evidence: %{proof: :current_pr_diff}}, :missing_current_pr_diff_path}
    ]

    Enum.with_index(cases, fn {finding, expected_reason}, index ->
      preceding = List.duplicate(scope_finding({:acceptance_criterion, "AC-1"}), index)

      assert {:error, {:unclusterable_finding, ^index, ^expected_reason}} =
               ReviewFindingCluster.cluster(preceding ++ [finding])
    end)
  end

  test "non-list finding collections fail closed" do
    Enum.each([nil, %{}, :invalid], fn findings ->
      assert ReviewFindingCluster.cluster(findings) == {:error, :invalid_findings}
    end)
  end

  defp scope_finding(reference, overrides \\ %{}) do
    Map.merge(
      %{
        route: :same_pr,
        evidence_code: :scope_contract_reference_verified,
        evidence: %{
          binding: %{base_sha: "base", head_sha: "head", path: "lib/example.ex"},
          scope_reference: reference
        },
        body: "finding prose",
        priority: 1,
        path: "lib/example.ex",
        url: "https://example.test/finding"
      },
      overrides
    )
  end

  defp current_diff_finding(path, overrides \\ %{}) do
    Map.merge(
      %{
        route: :same_pr,
        evidence_code: :current_pr_diff_verified,
        evidence: %{
          binding: %{base_sha: "base", head_sha: "head", path: path},
          proof: :current_pr_diff
        },
        body: "finding prose",
        priority: 2,
        path: path,
        url: "https://example.test/finding"
      },
      overrides
    )
  end
end
