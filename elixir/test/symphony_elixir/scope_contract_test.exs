defmodule SymphonyElixir.ScopeContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ScopeContract

  @complete_contract """
  #### Scope Contract

  ##### Work Item

  Add a typed PR scope contract parser.

  ##### Invariants

  - The parser reads only explicit Scope Contract headings.
  - Invalid contracts fail closed.

  ##### Acceptance Criteria

  - AC-1: Parse a complete scope contract.
  - AC-2: Aggregate validation errors.

  ##### Non-Goals

  - Do not change review routing.

  ##### Dependencies

  None

  ##### Follow-Ups

  None
  """

  test "returns a typed contract for every complete field" do
    # Mutation caught: returning a map, dropping a field, or mapping a section to the wrong field.
    assert {:ok, contract} = ScopeContract.parse_pr_body(@complete_contract)

    assert %{
             __struct__: ScopeContract,
             work_item: "Add a typed PR scope contract parser.",
             invariants: [
               "The parser reads only explicit Scope Contract headings.",
               "Invalid contracts fail closed."
             ],
             acceptance_criteria: [
               "AC-1: Parse a complete scope contract.",
               "AC-2: Aggregate validation errors."
             ],
             non_goals: ["Do not change review routing."],
             dependencies: [],
             follow_ups: []
           } = contract
  end

  test "returns a stable error when a required section is missing" do
    # Mutation caught: skipping required Work Item heading validation and returning a partial contract.
    body = """
    #### Scope Contract

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:missing_section, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "returns a stable error when a required list section is missing" do
    # Mutation caught: omitting Invariants from the required-section validation list.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:missing_section, :invariants}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects duplicate Scope Contract headings" do
    # Mutation caught: accepting the first duplicate Invariants section instead of failing closed.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - The parser reads only explicit Scope Contract headings.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:duplicate_section, :invariants}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects blank bullets and HTML placeholder comments" do
    # Mutation caught: normalizing an empty bullet or template comment into usable contract data.
    body = """
    #### Scope Contract

    ##### Work Item

    <!-- Describe the work item. -->

    ##### Invariants

    -

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:placeholder_comment, :work_item}, {:blank_bullet, :invariants}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "accepts None only for Dependencies and Follow-Ups" do
    # Mutation caught: treating None as an empty value for required invariant, criterion, or non-goal lists.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    None

    ##### Acceptance Criteria

    None

    ##### Non-Goals

    None

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:none_not_allowed, :invariants},
              {:none_not_allowed, :acceptance_criteria},
              {:none_not_allowed, :non_goals}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects bulleted None as a Work Item" do
    # Mutation caught: accepting a Markdown bullet as the single Work Item prose value.
    body = """
    #### Scope Contract

    ##### Work Item

    - None

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:none_not_allowed, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects explicit None as a Work Item" do
    # Mutation caught: treating Work Item like an optional list that permits the None marker.
    body = """
    #### Scope Contract

    ##### Work Item

    None

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:none_not_allowed, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects a blank Markdown bullet as a Work Item" do
    # Mutation caught: accepting a lone Markdown bullet as the single Work Item prose value.
    body = """
    #### Scope Contract

    ##### Work Item

    -

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:blank_bullet, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects a populated Markdown bullet as a Work Item" do
    # Mutation caught: stripping a Markdown bullet into apparently valid Work Item prose.
    body = """
    #### Scope Contract

    ##### Work Item

    - Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:malformed_bullet, :work_item, "- Add a typed PR scope contract parser."}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "rejects multiple prose values as a Work Item" do
    # Mutation caught: silently selecting one of multiple nonblank Work Item lines.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.
    Also change review routing.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:invalid_work_item, :multiple_values}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "rejects an unexpected Scope Contract subheading" do
    # Mutation caught: ignoring unknown structured fields that could hide an authoring mistake.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Ownership

    - Symphony governance.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:unexpected_section, "Ownership"}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects an acceptance criterion without a stable identifier" do
    # Mutation caught: accepting free-form acceptance-criteria bullets without an AC identifier.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:malformed_acceptance_criterion, "Parse a complete scope contract."}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "normalizes bullet None before required and optional list policies" do
    # Mutation caught: checking None before bullet normalization, which accepts required - None values.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - None

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None

    ##### Follow-Ups

    - None
    """

    assert {:error, [{:none_not_allowed, :invariants}]} = ScopeContract.parse_pr_body(body)
  end

  test "accepts bullet None as an explicit empty optional list" do
    # Mutation caught: treating normalized - None as a dependency value rather than the optional empty marker.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None

    ##### Follow-Ups

    - None
    """

    assert {:ok, %{dependencies: [], follow_ups: []}} = ScopeContract.parse_pr_body(body)
  end

  test "rejects mixed None and ordinary optional list values" do
    # Mutation caught: allowing None to coexist with a real dependency after bullet normalization.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None
    - Existing PR lint.

    ##### Follow-Ups

    None
    """

    assert {:error, [{:none_must_be_explicit, :dependencies}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects hyphen-prefixed text that is not a Markdown bullet" do
    # Mutation caught: stripping every leading hyphen and accepting -value or --value as list bullets.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    -value
    --value

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "-value"},
              {:malformed_bullet, :invariants, "--value"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects duplicate outer Scope Contract headings" do
    # Mutation caught: parsing only the first outer Scope Contract and silently ignoring a second contract.
    body = @complete_contract <> "\n#### Scope Contract\n\n##### Work Item\n\nConflicting contract.\n"

    assert {:error, [{:duplicate_scope_contract}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects duplicate stable acceptance-criterion identifiers" do
    # Mutation caught: validating AC syntax without detecting repeated stable identifiers.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.
    - AC-1: Aggregate validation errors.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:duplicate_acceptance_criterion, "AC-1"}]} = ScopeContract.parse_pr_body(body)
  end

  test "aggregates malformed bullets and malformed acceptance criteria from one list" do
    # Mutation caught: returning structural bullet errors before validating usable acceptance-criteria entries.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    malformed bullet
    - Missing a stable identifier.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :acceptance_criteria, "malformed bullet"},
              {:malformed_acceptance_criterion, "Missing a stable identifier."}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "aggregates malformed bullets and required None policy errors from one list" do
    # Mutation caught: skipping required None policy validation after a sibling bullet normalization error.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    malformed bullet
    - None

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "malformed bullet"},
              {:none_not_allowed, :invariants}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "ignores Scope Contract headings inside backtick and tilde fences" do
    # Mutation caught: counting fenced example headings or closing a fence with a shorter marker.
    body = """
    #### Context

    ````markdown
    #### Scope Contract
    ```
    #### Scope Contract
    ````

    ~~~~ text
    #### Scope Contract
    ~~~
    #### Scope Contract
    ~~~~~

    #### Scope Contract

    ##### Work Item

    Parse the real scope contract.

    ##### Invariants

    - Fenced examples do not create contracts.

    ##### Acceptance Criteria

    - AC-1: Parse the visible contract heading.

    ##### Non-Goals

    - Do not interpret prose semantically.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:ok,
            %{
              work_item: "Parse the real scope contract.",
              invariants: ["Fenced examples do not create contracts."],
              acceptance_criteria: ["AC-1: Parse the visible contract heading."]
            }} = ScopeContract.parse_pr_body(body)
  end

  test "keeps fenced headings inside a real list section as fail-closed content" do
    # Mutation caught: treating fenced ##### as a section or fenced #### as a scope terminator.
    body = """
    #### Scope Contract

    ##### Work Item

    Parse the real scope contract.

    ##### Invariants

    - Keep parsing the visible contract.
    ```markdown
    ##### Acceptance Criteria
    #### Premature Terminator
    ```
    - Keep parsing after the fenced example.

    ##### Acceptance Criteria

    - AC-1: Parse all visible sections.

    ##### Non-Goals

    - Do not interpret fenced headings as structure.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "```markdown"},
              {:malformed_bullet, :invariants, "##### Acceptance Criteria"},
              {:malformed_bullet, :invariants, "#### Premature Terminator"},
              {:malformed_bullet, :invariants, "```"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "joins legally indented Markdown list continuations" do
    # Mutation caught: requiring every physical line of one list item to repeat the bullet marker.
    body = """
    #### Scope Contract

    ##### Work Item

    Parse wrapped contract values.

    ##### Invariants

    - Invalid contracts remain
      fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse legal Markdown
        continuation indentation.

    ##### Non-Goals

    - Do not change
      review routing.

    ##### Dependencies

    - Existing PR lint
      integration.

    ##### Follow-Ups

    None
    """

    assert {:ok,
            %{
              invariants: ["Invalid contracts remain fail closed."],
              acceptance_criteria: ["AC-1: Parse legal Markdown continuation indentation."],
              non_goals: ["Do not change review routing."],
              dependencies: ["Existing PR lint integration."]
            }} = ScopeContract.parse_pr_body(body)
  end

  test "rejects an indented continuation before the first list bullet" do
    # Mutation caught: accepting an orphan continuation merely because it has legal continuation indentation.
    body = """
    #### Scope Contract

    ##### Work Item

    Parse wrapped contract values.

    ##### Invariants

      Orphaned continuation.
    - Invalid contracts remain
      fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:malformed_bullet, :invariants, "Orphaned continuation."}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "aggregates None and all remaining acceptance criterion errors in stable order" do
    # Mutation caught: returning the None policy error before validating other usable acceptance criteria.
    body = """
    #### Scope Contract

    ##### Work Item

    Aggregate all criterion errors.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - None
    - Missing a stable identifier.
    - AC-1: First criterion.
    - AC-1: Duplicate criterion.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:none_not_allowed, :acceptance_criteria},
              {:malformed_acceptance_criterion, "Missing a stable identifier."},
              {:duplicate_acceptance_criterion, "AC-1"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  @tag timeout: 2_500
  test "parses a large contract in stable source order without quadratic accumulation" do
    # Mutation caught: appending each parsed line to the accumulated list and repeatedly copying its prefix.
    bullets = Enum.map_join(1..40_000, "\n", fn index -> "- invariant #{index}" end)

    body = """
    #### Scope Contract

    ##### Work Item

    Parse a large scope contract.

    ##### Invariants

    #{bullets}

    ##### Acceptance Criteria

    - AC-1: Preserve source order.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:ok, %{invariants: invariants}} = ScopeContract.parse_pr_body(body)
    assert length(invariants) == 40_000
    assert hd(invariants) == "invariant 1"
    assert List.last(invariants) == "invariant 40000"
  end

  test "keeps None typed when a continuation follows in required and optional lists" do
    # Mutation caught: rewriting the None sentinel into ordinary text when an indented continuation follows it.
    body = """
    #### Scope Contract

    ##### Work Item

    Preserve typed normalized items.

    ##### Invariants

    - None
      must remain a sentinel.

    ##### Acceptance Criteria

    - AC-1: Fail closed on invalid sentinel continuations.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None
      must remain standalone.

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "must remain a sentinel."},
              {:none_not_allowed, :invariants},
              {:malformed_bullet, :dependencies, "must remain standalone."},
              {:none_must_be_explicit, :dependencies}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "does not consume indented Markdown block starts as paragraph continuations" do
    # Mutation caught: classifying every indented line as wrapped prose regardless of Markdown block structure.
    body = """
    #### Scope Contract

    ##### Work Item

    Preserve Markdown list structure.

    ##### Invariants

    - Keep the first invariant.
      - Nested dash item.
      * Alternate star item.
      + Alternate plus item.
      1. Ordered item.
      ## ATX heading.
      > Block quote.

    ##### Acceptance Criteria

    - AC-1: Reject nested Markdown blocks.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "- Nested dash item."},
              {:malformed_bullet, :invariants, "* Alternate star item."},
              {:malformed_bullet, :invariants, "+ Alternate plus item."},
              {:malformed_bullet, :invariants, "1. Ordered item."},
              {:malformed_bullet, :invariants, "## ATX heading."},
              {:malformed_bullet, :invariants, "> Block quote."}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "aggregates real subsection order with other structural errors" do
    # Mutation caught: reducing known headings directly into a map and discarding their source order.
    body = """
    #### Scope Contract

    ##### Work Item

    Validate the parsed heading sequence.

    ##### Acceptance Criteria

    - AC-1: Reject reordered visible headings.

    ##### Ownership

    - Symphony governance.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Invariants

    - Duplicate sections remain invalid.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:unexpected_section, "Ownership"},
              {:duplicate_section, :invariants},
              {:sections_out_of_order,
               [
                 :work_item,
                 :acceptance_criteria,
                 :invariants,
                 :invariants,
                 :dependencies,
                 :follow_ups
               ]},
              {:missing_section, :non_goals}
            ]} = ScopeContract.parse_pr_body(body)
  end

  for marker <- [
        "* Alternate bullet Work Item.",
        "+ Alternate bullet Work Item.",
        "1. Ordered Work Item.",
        "1) Parenthesized ordered Work Item."
      ] do
    test "rejects Work Item Markdown list marker #{marker}" do
      # Mutation caught: treating a non-dash Markdown list item as plain Work Item prose.
      marker = unquote(marker)
      body = String.replace(@complete_contract, "Add a typed PR scope contract parser.", marker)

      assert {:error, [{:malformed_bullet, :work_item, ^marker}]} = ScopeContract.parse_pr_body(body)
    end
  end

  test "rejects CommonMark thematic-break variants before bullet normalization" do
    # Mutation caught: stripping the first dash from a thematic break and accepting the remainder as a list value.
    Enum.each(["- - -", "-  -  -", "---", "***", "* * *", "___", "_ _ _"], fn thematic_break ->
      body =
        String.replace(
          @complete_contract,
          "- The parser reads only explicit Scope Contract headings.",
          thematic_break
        )

      assert {:error, [{:malformed_bullet, :invariants, ^thematic_break}]} =
               ScopeContract.parse_pr_body(body)
    end)
  end

  test "normalizes standard ATX closing hashes on outer and inner headings" do
    # Mutation caught: retaining the optional ATX closing sequence as part of the canonical heading title.
    body = """
    #### Scope Contract ####

    ##### Work Item #####

    Normalize visible headings.

    ##### Invariants #####

    - Invalid contracts fail closed.

    ##### Acceptance Criteria #####

    - AC-1: Normalize standard closing hashes.

    ##### Non-Goals #####

    - Do not change review routing.

    ##### Dependencies #####

    None

    ##### Follow-Ups #####

    None
    """

    assert {:ok,
            %{
              work_item: "Normalize visible headings.",
              invariants: ["Invalid contracts fail closed."],
              acceptance_criteria: ["AC-1: Normalize standard closing hashes."]
            }} = ScopeContract.parse_pr_body(body)
  end

  test "counts closing-hash outer headings when detecting duplicate Scope Contracts" do
    # Mutation caught: normalizing ATX titles only after duplicate outer-heading discovery.
    body = @complete_contract <> "\n#### Scope Contract ####\n"

    assert {:error, [{:duplicate_scope_contract}]} = ScopeContract.parse_pr_body(body)
  end

  for boundary <- ["# Outside Scope", "## Outside Scope", "### Outside Scope", "#### Outside Scope"] do
    test "stops Scope Contract at visible boundary #{boundary}" do
      # Mutation caught: terminating only at H4 and collecting outside H5 fields after an H1-H3 boundary.
      boundary = unquote(boundary)

      body = """
      #### Scope Contract

      ##### Work Item

      Stop at the first visible outer heading.

      ##### Invariants

      - Outside fields never complete this contract.

      #{boundary}

      ##### Acceptance Criteria

      - AC-1: This field is outside the contract.

      ##### Non-Goals

      - This field is outside the contract.

      ##### Dependencies

      None

      ##### Follow-Ups

      None
      """

      assert {:error,
              [
                {:missing_section, :acceptance_criteria},
                {:missing_section, :non_goals},
                {:missing_section, :dependencies},
                {:missing_section, :follow_ups}
              ]} = ScopeContract.parse_pr_body(body)
    end
  end

  test "keeps every heading level and closing hashes non-structural inside a fence" do
    # Mutation caught: normalizing fenced heading text into visible boundary or subsection tokens.
    body = """
    #### Scope Contract

    ##### Work Item

    Ignore fenced heading examples.

    ##### Invariants

    - Fenced headings remain content.
    ```markdown
    # H1 ####
    ## H2 ####
    ### H3 ####
    #### H4 ####
    ##### Acceptance Criteria #####
    ```

    ##### Acceptance Criteria

    - AC-1: Parse the real visible subsection.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "```markdown"},
              {:malformed_bullet, :invariants, "# H1 ####"},
              {:malformed_bullet, :invariants, "## H2 ####"},
              {:malformed_bullet, :invariants, "### H3 ####"},
              {:malformed_bullet, :invariants, "#### H4 ####"},
              {:malformed_bullet, :invariants, "##### Acceptance Criteria #####"},
              {:malformed_bullet, :invariants, "```"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects indented code as Work Item prose and invariant continuation" do
    # Mutation caught: treating document code indentation as Work Item text or list continuation indentation.
    work_item_body =
      String.replace(
        @complete_contract,
        "Add a typed PR scope contract parser.",
        "    IO.puts(\"not Work Item prose\")"
      )

    assert {:error, [{:malformed_bullet, :work_item, "IO.puts(\"not Work Item prose\")"}]} =
             ScopeContract.parse_pr_body(work_item_body)

    invariant_body =
      String.replace(
        @complete_contract,
        "- The parser reads only explicit Scope Contract headings.",
        "- The parser reads only explicit Scope Contract headings.\n      IO.puts(\"not continuation prose\")"
      )

    assert {:error, [{:malformed_bullet, :invariants, "IO.puts(\"not continuation prose\")"}]} =
             ScopeContract.parse_pr_body(invariant_body)
  end

  @tag timeout: 2_500
  test "tracks a large repeated-heading sequence without sorting it" do
    # Mutation caught: materializing and sorting all observed heading ranks after section reduction.
    duplicate_count = 40_000
    repeated_headings = String.duplicate("##### Invariants\n\n", duplicate_count)

    body = """
    #### Scope Contract

    ##### Work Item

    Track order during reduction.

    #{repeated_headings}
    ##### Acceptance Criteria

    - AC-1: Preserve linear heading validation.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, errors} = ScopeContract.parse_pr_body(body)
    assert length(errors) == duplicate_count
    assert hd(errors) == {:duplicate_section, :invariants}
    assert List.last(errors) == {:empty_section, :invariants}
    refute Enum.any?(errors, &match?({:sections_out_of_order, _fields}, &1))
  end

  test "fails closed on an empty visible H5 section heading" do
    # Mutation caught: treating an H5 token with no normalized title as ordinary section content.
    body = String.replace(@complete_contract, "#### Scope Contract\n\n", "#### Scope Contract\n\n#####\n\n")

    assert {:error, [{:malformed_section_heading, "#####"}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects an indented fence marker whose backtick info makes it an invalid opening fence" do
    # Mutation caught: dropping :fence_marker classification and appending the invalid marker as continuation prose.
    body =
      String.replace(
        @complete_contract,
        "- The parser reads only explicit Scope Contract headings.",
        "- The parser reads only explicit Scope Contract headings.\n  ```bad`info"
      )

    assert {:error, [{:malformed_bullet, :invariants, "```bad`info"}]} = ScopeContract.parse_pr_body(body)
  end

  test "uses tab stops to distinguish Work Item code, list continuation, and nested code" do
    # Mutation caught: leaving tabs in token text instead of advancing the canonical indentation column.
    work_item_body =
      String.replace(
        @complete_contract,
        "Add a typed PR scope contract parser.",
        "\tIO.puts(\"tab-indented Work Item code\")"
      )

    assert {:error, [{:malformed_bullet, :work_item, "IO.puts(\"tab-indented Work Item code\")"}]} =
             ScopeContract.parse_pr_body(work_item_body)

    continuation_body =
      String.replace(
        @complete_contract,
        "- The parser reads only explicit Scope Contract headings.",
        "- The parser reads only explicit Scope Contract headings.\n\tthrough one tab stop."
      )

    assert {:ok,
            %{
              invariants: [
                "The parser reads only explicit Scope Contract headings. through one tab stop.",
                "Invalid contracts fail closed."
              ]
            }} = ScopeContract.parse_pr_body(continuation_body)

    code_body =
      String.replace(
        @complete_contract,
        "- The parser reads only explicit Scope Contract headings.",
        "- The parser reads only explicit Scope Contract headings.\n\t\tIO.puts(\"nested tab code\")"
      )

    assert {:error, [{:malformed_bullet, :invariants, "IO.puts(\"nested tab code\")"}]} =
             ScopeContract.parse_pr_body(code_body)
  end

  test "resolves only exact typed references from a parsed contract" do
    # Mutations caught: matching nearby prose, accepting an unknown AC ID, or treating an absent dependency as present.
    body =
      @complete_contract
      |> String.replace("None\n\n##### Follow-Ups", "- PR #8 is merged.\n\n##### Follow-Ups")

    assert {:ok, contract} = ScopeContract.parse_pr_body(body)

    assert ScopeContract.reference_exists?(contract, {:acceptance_criterion, "AC-1"})
    refute ScopeContract.reference_exists?(contract, {:acceptance_criterion, "AC-3"})
    refute ScopeContract.reference_exists?(contract, {:acceptance_criterion, "AC-1:"})

    assert ScopeContract.reference_exists?(
             contract,
             {:invariant, "The parser reads only explicit Scope Contract headings."}
           )

    refute ScopeContract.reference_exists?(
             contract,
             {:invariant, "parser reads only explicit Scope Contract headings"}
           )

    assert ScopeContract.reference_exists?(contract, {:dependency, "PR #8 is merged."})
    refute ScopeContract.reference_exists?(contract, {:dependency, "PR #8"})
  end
end
