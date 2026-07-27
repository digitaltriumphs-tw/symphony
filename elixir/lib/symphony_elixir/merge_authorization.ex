defmodule SymphonyElixir.MergeAuthorization do
  @moduledoc """
  Pure, fail-closed policy for exact-head merge authorization.

  Review convergence remains a separate technical signal. This policy consumes its durable hold
  or release evidence plus a read-only GitHub ruleset receipt; it performs no external effects.
  """

  @required_context "Review Convergence Gate"
  @safe_methods ~w(merge squash rebase)

  defmodule State do
    @moduledoc "Typed current state projected by the orchestrator and observability surfaces."

    @type status :: :holding | :ruleset_unverified | :merge_ready | :merge_failed | :merged

    @type t :: %__MODULE__{
            status: status(),
            reason: atom() | nil,
            repository: String.t() | nil,
            pull_request_number: pos_integer() | nil,
            base_sha: String.t() | nil,
            head_sha: String.t() | nil,
            operation_id: String.t() | nil,
            method: String.t() | nil,
            failure: atom() | nil,
            pending_receipt: map() | nil,
            receipts: [map()]
          }

    defstruct [
      :status,
      :reason,
      :repository,
      :pull_request_number,
      :base_sha,
      :head_sha,
      :operation_id,
      :method,
      :failure,
      :pending_receipt,
      receipts: []
    ]
  end

  @type input :: %{
          required(:settings) => map(),
          required(:issue_id) => String.t(),
          required(:snapshot) => map(),
          required(:convergence_history) => map(),
          required(:merge_history) => map(),
          required(:ruleset_receipt) => map() | nil
        }

  @type operation_identity :: %{
          required(:repository) => String.t() | nil,
          required(:pull_request_number) => pos_integer() | nil,
          required(:base_sha) => String.t() | nil,
          required(:head_sha) => String.t() | nil,
          required(:operation_id) => String.t(),
          required(:method) => String.t() | nil
        }

  @spec evaluate(input()) :: State.t()
  def evaluate(%{} = input) do
    binding = binding(input.issue_id, input.snapshot, input.settings[:method])
    merge_history = normalize_merge_history(input.merge_history)
    operation_id = binding.operation_id
    release = merge_history.releases[operation_id]
    intent = merge_history.intents[operation_id]
    completion = merge_history.completions[operation_id]
    failure = merge_history.failures[operation_id]

    case precondition_failure(input, binding, merge_history, release) do
      nil -> terminal_state(binding, intent, completion, failure, release)
      {status, reason} -> state(binding, status, reason, nil, [])
    end
  end

  defp precondition_failure(input, binding, merge_history, release) do
    cond do
      input.settings[:enabled] != true ->
        {:holding, :disabled}

      invalid_binding?(binding) ->
        {:holding, :invalid_binding}

      not is_nil(merge_history.ledger_error) ->
        {:holding, :invalid_merge_ledger}

      convergence_hold?(input.convergence_history, binding.head_sha) ->
        {:holding, :convergence_hold}

      not verified_ruleset?(input.ruleset_receipt, binding) ->
        {:ruleset_unverified, :ruleset_unverified}

      not exact_release?(release, binding) ->
        {:holding, :release_unverified}

      true ->
        nil
    end
  end

  defp terminal_state(binding, intent, completion, failure, release) do
    cond do
      exact_completion?(completion, binding) ->
        state(binding, :merged, nil, nil, compact_receipts([release, intent, completion]))

      exact_failure?(failure, binding) ->
        state(
          binding,
          :merge_failed,
          :github_merge_failed,
          failure.failure,
          compact_receipts([release, intent, failure])
        )

      not is_nil(intent) and not exact_intent?(intent, binding) ->
        state(binding, :holding, :intent_unverified, nil, [release])

      true ->
        state(binding, :merge_ready, nil, nil, compact_receipts([release, intent]))
    end
  end

  @spec operation_id(String.t(), map()) :: String.t()
  def operation_id(issue_id, snapshot) when is_binary(issue_id) and is_map(snapshot) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        :merge_authorization_v1,
        issue_id,
        snapshot[:repository],
        snapshot[:pull_request_number],
        snapshot[:base_ref_oid],
        snapshot[:current_head_sha]
      })
    )
    |> Base.encode16(case: :lower)
  end

  @spec operation_identity(String.t(), map(), String.t() | nil) :: operation_identity()
  def operation_identity(issue_id, snapshot, method)
      when is_binary(issue_id) and is_map(snapshot) do
    %{
      repository: snapshot[:repository],
      pull_request_number: snapshot[:pull_request_number],
      base_sha: snapshot[:base_ref_oid],
      head_sha: snapshot[:current_head_sha],
      operation_id: operation_id(issue_id, snapshot),
      method: method
    }
  end

  @spec release_event(String.t(), map()) :: map()
  def release_event(issue_id, snapshot) when is_binary(issue_id) and is_map(snapshot) do
    issue_id
    |> binding(snapshot, nil)
    |> Map.take([:operation_id, :repository, :pull_request_number, :base_sha, :head_sha])
    |> Map.put(:kind, :authorization_release)
  end

  defp binding(issue_id, snapshot, method) do
    issue_id
    |> operation_identity(snapshot, method)
    |> Map.put(:base_ref, snapshot[:base_ref_name])
  end

  defp invalid_binding?(binding) do
    not (is_binary(binding.repository) and binding.repository != "" and
           is_integer(binding.pull_request_number) and binding.pull_request_number > 0 and
           is_binary(binding.base_ref) and binding.base_ref != "" and valid_sha?(binding.base_sha) and
           valid_sha?(binding.head_sha) and binding.method in @safe_methods)
  end

  defp convergence_hold?(history, head_sha) do
    history
    |> Map.get(:holds_by_head, %{})
    |> Map.has_key?(head_sha)
  end

  defp verified_ruleset?(
         %{
           status: :verified,
           strict: true,
           required_context: @required_context,
           repository: repository,
           base_ref: base_ref
         },
         %{repository: repository, base_ref: base_ref}
       ),
       do: true

  defp verified_ruleset?(_receipt, _binding), do: false

  defp exact_release?(%{kind: :authorization_release} = event, binding),
    do: exact_common_binding?(event, binding)

  defp exact_release?(_event, _binding), do: false

  defp exact_intent?(%{kind: :merge_intent, method: method} = event, %{method: method} = binding),
    do: exact_common_binding?(event, binding)

  defp exact_intent?(_event, _binding), do: false

  defp exact_completion?(%{kind: :merge_completed, method: method, merge_sha: merge_sha} = event, %{method: method} = binding) do
    exact_common_binding?(event, binding) and valid_sha?(merge_sha)
  end

  defp exact_completion?(_event, _binding), do: false

  defp exact_failure?(%{kind: :merge_failed, method: method, failure: failure} = event, %{method: method} = binding)
       when is_atom(failure),
       do: exact_common_binding?(event, binding)

  defp exact_failure?(_event, _binding), do: false

  defp exact_common_binding?(event, binding) do
    event.operation_id == binding.operation_id and
      event.repository == binding.repository and
      event.pull_request_number == binding.pull_request_number and
      event.base_sha == binding.base_sha and
      event.head_sha == binding.head_sha
  end

  defp state(binding, status, reason, failure, receipts) do
    struct(
      State,
      Map.merge(binding, %{
        status: status,
        reason: reason,
        failure: failure,
        pending_receipt: nil,
        receipts: receipts
      })
    )
  end

  defp normalize_merge_history(history) when is_map(history) do
    Map.merge(
      %{releases: %{}, intents: %{}, completions: %{}, failures: %{}, ledger_error: nil},
      history
    )
  end

  defp normalize_merge_history(_history),
    do: %{releases: %{}, intents: %{}, completions: %{}, failures: %{}, ledger_error: :invalid_history}

  defp compact_receipts(receipts), do: Enum.reject(receipts, &is_nil/1)

  defp valid_sha?(value), do: is_binary(value) and byte_size(value) in [40, 64] and value =~ ~r/\A[0-9a-f]+\z/
end
