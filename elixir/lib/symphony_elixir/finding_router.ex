defmodule SymphonyElixir.FindingRouter do
  @moduledoc """
  Extracts and verifies typed review-finding dispositions without inferring ownership from prose.

  The router is the authority for disposition schema, immutable reviewer identity, current PR
  binding, and Scope Contract references. Review body text, severity, URLs, and filenames never
  establish scope ownership.
  """

  alias SymphonyElixir.ScopeContract

  @sentinel "<!-- symphony-finding-disposition:v1"
  @sentinel_close "-->"
  @max_disposition_bytes 8_192

  @trusted_actors MapSet.new([
                    {"chatgpt-codex-connector", "Organization", 261_883_814},
                    {"chatgpt-codex-connector", "Bot", 199_175_422},
                    {"chatgpt-codex-connector[bot]", "Bot", 199_175_422}
                  ])

  @kind_by_wire_value %{
    "same_pr" => :same_pr,
    "introduced_by_pr" => :introduced_by_pr,
    "prerequisite" => :prerequisite,
    "follow_up" => :follow_up,
    "human_hold" => :human_hold
  }

  @root_keys %{
    same_pr: MapSet.new(["schema_version", "kind", "binding", "scope_ref"]),
    introduced_by_pr: MapSet.new(["schema_version", "kind", "binding", "proof"]),
    prerequisite: MapSet.new(["schema_version", "kind", "binding", "scope_ref"]),
    follow_up: MapSet.new(["schema_version", "kind", "binding", "relation"]),
    human_hold: MapSet.new(["schema_version", "kind", "binding"])
  }

  @binding_keys MapSet.new(["base_sha", "head_sha", "path"])

  @type route :: :same_pr | :prerequisite | :follow_up | :human_hold
  @type disposition_kind :: :same_pr | :introduced_by_pr | :prerequisite | :follow_up | :human_hold
  @type normalization_error :: :malformed | :duplicate | :too_large
  @type normalized_disposition :: :missing | {:error, normalization_error()} | {:decoded, map()}
  @type current_binding :: %{required(:base_sha) => String.t(), required(:head_sha) => String.t()}

  @type evidence_code ::
          :scope_contract_reference_verified
          | :current_pr_diff_verified
          | :scope_contract_dependency_verified
          | :follow_up_relation_verified
          | :explicit_human_hold
          | :missing_disposition
          | :malformed_disposition
          | :duplicate_disposition
          | :oversized_disposition
          | :untrusted_disposition_actor
          | :unsupported_schema_version
          | :unknown_disposition_kind
          | :unknown_disposition_field
          | :binding_mismatch
          | :missing_finding_identity
          | :invalid_scope_reference
          | :scope_reference_mismatch
          | :invalid_current_pr_diff_proof
          | :invalid_follow_up_relation

  @type routed_record :: %{
          required(:thread_id) => String.t() | nil,
          required(:finding_comment_id) => String.t() | nil,
          required(:route) => route(),
          required(:evidence_code) => evidence_code(),
          required(:evidence_display) => String.t(),
          required(:original_kind) => disposition_kind() | nil,
          required(:priority) => term(),
          required(:path) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:evidence) => map()
        }

  @spec extract_disposition(String.t()) :: normalized_disposition()
  def extract_disposition(body) when is_binary(body) do
    lines = body |> String.replace("\r\n", "\n") |> String.split("\n")
    %{blocks: blocks, open_count: open_count, disposition: disposition} = collect_blocks(lines)

    cond do
      open_count > 1 ->
        {:error, :duplicate}

      not is_nil(disposition) ->
        {:error, :malformed}

      blocks == [] ->
        :missing

      true ->
        decode_block(hd(blocks))
    end
  end

  @spec route(ScopeContract.t(), map(), current_binding()) :: routed_record()
  def route(%ScopeContract{} = contract, finding, current_binding)
      when is_map(finding) and is_map(current_binding) do
    record = base_record(finding)

    with :ok <- validate_finding_identity(finding),
         {:ok, payload} <- disposition_payload(finding[:disposition]),
         :ok <- validate_actor(finding[:disposition_actor]),
         :ok <- validate_schema_version(payload),
         {:ok, kind} <- disposition_kind(payload) do
      verify_known_disposition(contract, finding, current_binding, payload, kind, record)
    else
      {:error, code} -> hold(record, code)
    end
  end

  defp collect_blocks(lines) do
    initial = %{blocks: [], open_count: 0, disposition: nil, fence: nil}

    lines
    |> Enum.reduce(initial, &collect_line/2)
    |> Map.update!(:blocks, &Enum.reverse/1)
  end

  defp collect_line(line, %{disposition: disposition} = state) when is_list(disposition) do
    if line == @sentinel_close do
      block = disposition |> Enum.reverse() |> Enum.join("\n")
      %{state | blocks: [block | state.blocks], disposition: nil}
    else
      %{state | disposition: [line | disposition]}
    end
  end

  defp collect_line(line, %{fence: fence} = state) when not is_nil(fence) do
    if closing_fence?(line, fence), do: %{state | fence: nil}, else: state
  end

  defp collect_line(@sentinel, state) do
    %{state | disposition: [], open_count: state.open_count + 1}
  end

  defp collect_line(line, state) do
    case opening_fence(line) do
      nil -> state
      fence -> %{state | fence: fence}
    end
  end

  defp opening_fence(line) do
    with {:ok, content} <- document_content(line),
         marker when marker in ["`", "~"] <- String.first(content),
         {count, rest} <- leading_marker(content, marker),
         true <- count >= 3,
         true <- marker != "`" or not String.contains?(rest, "`") do
      {marker, count}
    else
      _ -> nil
    end
  end

  defp closing_fence?(line, {marker, opening_count}) do
    with {:ok, content} <- document_content(line),
         {count, rest} <- leading_marker(content, marker) do
      count >= opening_count and String.trim(rest) == ""
    else
      _ -> false
    end
  end

  defp document_content(line) do
    content = String.trim_leading(line, " ")
    indentation = byte_size(line) - byte_size(content)

    if indentation <= 3, do: {:ok, content}, else: :error
  end

  defp leading_marker(content, marker), do: leading_marker(content, marker, 0)

  defp leading_marker(<<marker::binary-size(1), rest::binary>>, marker, count),
    do: leading_marker(rest, marker, count + 1)

  defp leading_marker(rest, _marker, count), do: {count, rest}

  defp decode_block(block) when byte_size(block) > @max_disposition_bytes, do: {:error, :too_large}

  defp decode_block(block) do
    case Jason.decode(block) do
      {:ok, decoded} when is_map(decoded) -> {:decoded, decoded}
      _other -> {:error, :malformed}
    end
  end

  defp base_record(finding) do
    %{
      thread_id: finding[:thread_id],
      finding_comment_id: finding[:finding_comment_id],
      route: :human_hold,
      evidence_code: :malformed_disposition,
      evidence_display: display(:malformed_disposition),
      original_kind: nil,
      priority: finding[:priority],
      path: finding[:path],
      url: finding[:url],
      evidence: %{}
    }
  end

  defp validate_finding_identity(finding) do
    if nonblank?(finding[:thread_id]) and nonblank?(finding[:finding_comment_id]),
      do: :ok,
      else: {:error, :missing_finding_identity}
  end

  defp disposition_payload(:missing), do: {:error, :missing_disposition}
  defp disposition_payload({:error, :malformed}), do: {:error, :malformed_disposition}
  defp disposition_payload({:error, :duplicate}), do: {:error, :duplicate_disposition}
  defp disposition_payload({:error, :too_large}), do: {:error, :oversized_disposition}
  defp disposition_payload({:decoded, payload}) when is_map(payload), do: {:ok, payload}
  defp disposition_payload(_disposition), do: {:error, :malformed_disposition}

  defp validate_actor(actor) when is_map(actor) do
    identity = {actor["login"], actor["__typename"], actor["databaseId"]}

    if MapSet.member?(@trusted_actors, identity),
      do: :ok,
      else: {:error, :untrusted_disposition_actor}
  end

  defp validate_actor(_actor), do: {:error, :untrusted_disposition_actor}

  defp validate_schema_version(%{"schema_version" => 1}), do: :ok
  defp validate_schema_version(_payload), do: {:error, :unsupported_schema_version}

  defp disposition_kind(payload) do
    case Map.fetch(@kind_by_wire_value, payload["kind"]) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :unknown_disposition_kind}
    end
  end

  defp verify_known_disposition(contract, finding, current_binding, payload, kind, record) do
    with :ok <- exact_keys(payload, Map.fetch!(@root_keys, kind)),
         {:ok, binding} <- validate_binding(payload["binding"], finding, current_binding) do
      route_kind(contract, payload, kind, binding, record)
    else
      {:error, code} -> hold(record, code, kind)
    end
  end

  defp exact_keys(value, expected) when is_map(value) do
    actual = value |> Map.keys() |> MapSet.new()

    cond do
      not MapSet.subset?(actual, expected) -> {:error, :unknown_disposition_field}
      actual != expected -> {:error, :malformed_disposition}
      true -> :ok
    end
  end

  defp exact_keys(_value, _expected), do: {:error, :malformed_disposition}

  defp validate_binding(binding, finding, current_binding) do
    with :ok <- exact_keys(binding, @binding_keys),
         true <- nonblank?(current_binding[:base_sha]),
         true <- nonblank?(current_binding[:head_sha]),
         true <- nonblank?(finding[:path]),
         true <- binding["base_sha"] == current_binding[:base_sha],
         true <- binding["head_sha"] == current_binding[:head_sha],
         true <- binding["path"] == finding[:path] do
      {:ok,
       %{
         base_sha: binding["base_sha"],
         head_sha: binding["head_sha"],
         path: binding["path"]
       }}
    else
      {:error, code} -> {:error, code}
      _mismatch -> {:error, :binding_mismatch}
    end
  end

  defp route_kind(contract, payload, :same_pr, binding, record) do
    with {:ok, reference} <- same_pr_reference(payload["scope_ref"]),
         true <- ScopeContract.reference_exists?(contract, reference) do
      verified(
        record,
        :same_pr,
        :scope_contract_reference_verified,
        :same_pr,
        reference_display(reference),
        %{binding: binding, scope_reference: reference}
      )
    else
      {:error, code} -> hold(record, code, :same_pr)
      false -> hold(record, :scope_reference_mismatch, :same_pr)
    end
  end

  defp route_kind(_contract, payload, :introduced_by_pr, binding, record) do
    case exact_current_pr_diff_proof(payload["proof"]) do
      :ok ->
        verified(
          record,
          :same_pr,
          :current_pr_diff_verified,
          :introduced_by_pr,
          "Current PR diff at #{binding.path}",
          %{binding: binding, proof: :current_pr_diff}
        )

      {:error, code} ->
        hold(record, code, :introduced_by_pr)
    end
  end

  defp route_kind(contract, payload, :prerequisite, binding, record) do
    with {:ok, reference} <- dependency_reference(payload["scope_ref"]),
         true <- ScopeContract.reference_exists?(contract, reference) do
      {:dependency, value} = reference

      verified(
        record,
        :prerequisite,
        :scope_contract_dependency_verified,
        :prerequisite,
        "Scope Contract dependency: #{value}",
        %{binding: binding, scope_reference: reference}
      )
    else
      {:error, code} -> hold(record, code, :prerequisite)
      false -> hold(record, :scope_reference_mismatch, :prerequisite)
    end
  end

  defp route_kind(_contract, payload, :follow_up, binding, record) do
    case payload["relation"] do
      "adjacent" ->
        verified_follow_up(record, binding, :adjacent)

      "pre_existing" ->
        verified_follow_up(record, binding, :pre_existing)

      _relation ->
        hold(record, :invalid_follow_up_relation, :follow_up)
    end
  end

  defp route_kind(_contract, _payload, :human_hold, binding, record) do
    verified(
      record,
      :human_hold,
      :explicit_human_hold,
      :human_hold,
      "Trusted reviewer requested human disposition",
      %{binding: binding}
    )
  end

  defp same_pr_reference(reference) when is_map(reference) do
    cond do
      exact_map?(reference, ["type", "id"]) and reference["type"] == "acceptance_criterion" and
          nonblank?(reference["id"]) ->
        {:ok, {:acceptance_criterion, reference["id"]}}

      exact_map?(reference, ["type", "value"]) and reference["type"] == "invariant" and
          nonblank?(reference["value"]) ->
        {:ok, {:invariant, reference["value"]}}

      unknown_reference_keys?(reference, [["type", "id"], ["type", "value"]]) ->
        {:error, :unknown_disposition_field}

      true ->
        {:error, :invalid_scope_reference}
    end
  end

  defp same_pr_reference(_reference), do: {:error, :invalid_scope_reference}

  defp dependency_reference(reference) when is_map(reference) do
    cond do
      exact_map?(reference, ["type", "value"]) and reference["type"] == "dependency" and
          nonblank?(reference["value"]) ->
        {:ok, {:dependency, reference["value"]}}

      unknown_reference_keys?(reference, [["type", "value"]]) ->
        {:error, :unknown_disposition_field}

      true ->
        {:error, :invalid_scope_reference}
    end
  end

  defp dependency_reference(_reference), do: {:error, :invalid_scope_reference}

  defp exact_current_pr_diff_proof(proof) do
    cond do
      exact_map?(proof, ["type"]) and proof["type"] == "current_pr_diff" -> :ok
      is_map(proof) and not exact_map?(proof, ["type"]) -> {:error, :unknown_disposition_field}
      true -> {:error, :invalid_current_pr_diff_proof}
    end
  end

  defp exact_map?(value, keys) when is_map(value), do: MapSet.new(Map.keys(value)) == MapSet.new(keys)
  defp exact_map?(_value, _keys), do: false

  defp unknown_reference_keys?(reference, allowed_shapes) do
    actual = MapSet.new(Map.keys(reference))

    Enum.all?(allowed_shapes, fn shape ->
      not MapSet.subset?(actual, MapSet.new(shape))
    end)
  end

  defp verified_follow_up(record, binding, relation) do
    verified(
      record,
      :follow_up,
      :follow_up_relation_verified,
      :follow_up,
      "Follow-up relation: #{relation}",
      %{binding: binding, relation: relation}
    )
  end

  defp verified(record, route, code, kind, evidence_display, evidence) do
    %{
      record
      | route: route,
        evidence_code: code,
        evidence_display: evidence_display,
        original_kind: kind,
        evidence: evidence
    }
  end

  defp hold(record, code, kind \\ nil) do
    %{record | evidence_code: code, evidence_display: display(code), original_kind: kind}
  end

  defp display(:missing_finding_identity), do: "Finding thread or comment identity is missing"
  defp display(:missing_disposition), do: "Disposition metadata is missing"
  defp display(:malformed_disposition), do: "Disposition metadata is malformed"
  defp display(:duplicate_disposition), do: "Disposition metadata is duplicated"
  defp display(:oversized_disposition), do: "Disposition metadata exceeds the size limit"
  defp display(:untrusted_disposition_actor), do: "Disposition actor is not trusted"
  defp display(:unsupported_schema_version), do: "Disposition schema version is unsupported"
  defp display(:unknown_disposition_kind), do: "Disposition kind is unknown"
  defp display(:unknown_disposition_field), do: "Disposition includes an unknown field"
  defp display(:binding_mismatch), do: "Disposition does not match the current finding binding"
  defp display(:invalid_scope_reference), do: "Disposition scope reference is malformed"
  defp display(:scope_reference_mismatch), do: "Disposition scope reference is not in the Scope Contract"
  defp display(:invalid_current_pr_diff_proof), do: "Disposition current-PR proof is invalid"
  defp display(:invalid_follow_up_relation), do: "Disposition follow-up relation is invalid"

  defp reference_display({:acceptance_criterion, identifier}),
    do: "Scope Contract acceptance criterion #{identifier}"

  defp reference_display({:invariant, value}), do: "Scope Contract invariant: #{value}"

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
