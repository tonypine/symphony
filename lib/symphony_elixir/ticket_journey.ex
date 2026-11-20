defmodule SymphonyElixir.TicketJourney do
  @moduledoc """
  What a run reads of a ticket in place of its description: the steps QA walks, the acceptance
  list, the proofs recorded for them, and the text a prompt carries.

  A groomed ticket (`SymphonyElixir.TicketPlan.groomed?/1`) answers from its plan and its checks
  (`SymphonyElixir.TicketChecks`), and no run reads its Linear description:

    * a `qa` check is a step QA walks: its statement, the app state it needs, the action and what
      to expect, under the check's id (`[c2]`). A step's number is the check's place in the plan,
      so one check has one number whoever reads it;
    * an `outcome` check is an acceptance criterion;
    * a `check.proved` with `by: test` is the proof of its check, which the QA pre-check confirms on
      the PR head as it confirms a walkthrough step's recorded proof; QA walks every other `qa`
      check on each head it judges. A waived check is nobody's to prove, so it is no step and no
      criterion;
    * the prompt carries `## Ask`, `## Plan` and `## Checks` (`plan_text/1`).

  A ticket that is not groomed answers what the callers computed before plans, from the
  description's `## User walkthrough` (`SymphonyElixir.Walkthrough`) or from the parser the caller
  hands in: nothing changes for it.
  """

  alias SymphonyElixir.{PromptSafety, TicketChecks, TicketPlan, Walkthrough}

  @screen_layers ["screen", "gallery"]
  # The proofs an implementation run owes before it hands the ticket off (`unproved/1`).
  @handoff_proofs ["test", "attached"]
  # The proofs QA gives: a test of the PR never stands in for them.
  @qa_proofs ["qa", "design"]

  @typedoc "A ticket: its issue (a struct or a map with `id` and `description`) or its issue id."
  @type ticket :: map() | String.t() | nil

  @typedoc "A step QA walks or links, as `SymphonyElixir.Walkthrough` gives one; a groomed ticket's names its check."
  @type step :: Walkthrough.step()

  @typedoc "A proof the implementer names for a check: the check's id and the test."
  @type check_proof :: %{check_id: String.t(), test: String.t()}

  @doc "Whether the ticket is groomed: its history holds a plan."
  @spec groomed?(ticket()) :: boolean()
  def groomed?(ticket) do
    case id(ticket) do
      nil -> false
      id -> TicketPlan.groomed?(id)
    end
  end

  @doc """
  The steps of the ticket, in order, each with the proof recorded for it: QA's to walk, or a named
  test's when one was recorded and the repo has a `proof_check`. For a groomed ticket they are its
  `qa` checks; else the numbered steps of the description's `## User walkthrough`.
  """
  @spec steps(ticket(), String.t() | nil) :: [step()]
  def steps(ticket, proof_check \\ nil) do
    if groomed?(ticket) do
      numbered = numbered(ticket)
      numbered |> walked() |> proved(numbered, proof_check)
    else
      walkthrough_steps(ticket, proof_check)
    end
  end

  @doc """
  The steps a recorded test proves, from the ticket's events alone: the QA pre-check's input. For
  a groomed ticket they are the checks, of any kind, a `check.proved` with `by: test` names. With
  no `proof_check` there are none.
  """
  @spec proof_steps(ticket(), String.t() | nil) :: [step()]
  def proof_steps(ticket, proof_check) do
    if groomed?(ticket) do
      numbered = numbered(ticket)
      numbered |> Enum.map(&step/1) |> proved(numbered, proof_check) |> Enum.filter(&Walkthrough.named_test?/1)
    else
      Walkthrough.proof_steps(Walkthrough.recorded_proofs(id(ticket)), proof_check)
    end
  end

  @doc """
  Whether the ticket has anything for QA to walk: a `qa` check for a groomed ticket, else what
  `ungroomed` answers for the description (by default, whether it has a `## User walkthrough`).
  """
  @spec walkthrough?(ticket(), (String.t() | nil -> boolean())) :: boolean()
  def walkthrough?(ticket, ungroomed \\ &(Walkthrough.section(&1) != nil)) do
    if groomed?(ticket), do: ticket |> numbered() |> walked() != [], else: ungroomed.(description(ticket))
  end

  @doc """
  The journey a groomed ticket gives QA (`SymphonyElixir.QaVerification.journey/3`): its `qa`
  checks as the steps and as the text. Nil for a ticket that is not groomed, whose journey is read
  from its description.
  """
  @typedoc "What QA verifies: where it comes from, its text and its steps."
  @type journey :: %{source: String.t(), text: String.t(), steps: [step()]}

  @spec journey(ticket(), String.t() | nil, String.t()) :: journey() | nil
  def journey(ticket, proof_check, label \\ "the ticket") do
    if groomed?(ticket) do
      steps = steps(ticket, proof_check)
      %{source: "the QA checks of #{label}'s plan", text: journey_text(steps), steps: steps}
    end
  end

  defp journey_text([]), do: "The plan names no QA check: no step is yours to walk."
  defp journey_text(steps), do: Enum.map_join(steps, "\n", &"#{&1.number}. #{&1.text}")

  @doc """
  The text of the steps QA walks, those no recorded test proves: "" when a test proves every one,
  nil when the ticket has no step. A walkthrough with no numbered step is walked whole.
  """
  @spec walked_text(ticket(), String.t() | nil) :: String.t() | nil
  def walked_text(ticket, proof_check) do
    if groomed?(ticket) do
      case steps(ticket, proof_check) do
        [] -> nil
        steps -> unproved_text(steps)
      end
    else
      section = Walkthrough.section(description(ticket))

      case section && Walkthrough.steps(section) do
        nil -> nil
        [] -> section
        steps -> steps |> recorded(ticket, proof_check) |> unproved_text()
      end
    end
  end

  defp unproved_text(steps), do: steps |> Enum.reject(&Walkthrough.named_test?/1) |> Enum.map_join("\n", & &1.text)

  @doc """
  The acceptance list: a groomed ticket's `outcome` checks, one line each under its id, else what
  `ungroomed` reads from the description.
  """
  @spec acceptance(ticket(), (String.t() | nil -> [String.t()])) :: [String.t()]
  def acceptance(ticket, ungroomed \\ fn _description -> [] end) do
    if groomed?(ticket) do
      for {%{kind: "outcome", state: state} = check, _number} <- numbered(ticket), state != :waived, do: "[#{check.id}] #{one_line(check.statement)}"
    else
      ungroomed.(description(ticket))
    end
  end

  @doc "Whether a groomed ticket's plan says the change shows on screen (its layers hold `screen` or `gallery`)."
  @spec on_screen?(ticket()) :: boolean()
  def on_screen?(ticket) do
    case plan(ticket) do
      %{layers: layers} when is_list(layers) -> Enum.any?(layers, &(&1 in @screen_layers))
      _none -> false
    end
  end

  @doc """
  What a run's prompt carries of a groomed ticket in place of its description: `## Ask` (every ask,
  oldest first, as written), `## Plan` (the plan's text) and `## Checks` (one line per check: its
  id, kind, how it is proved, where it stands and its statement, and under a `qa` check what it
  needs, the action and what to expect). Nil for a ticket that is not groomed.
  """
  @spec plan_text(ticket()) :: String.t() | nil
  def plan_text(ticket) do
    case plan(ticket) do
      nil ->
        nil

      plan ->
        id = id(ticket)
        "## Ask\n\n#{asks(id)}\n\n## Plan\n\n#{plan_words(plan)}\n\n## Checks\n\n#{check_lines(TicketChecks.list(id))}"
    end
  end

  @doc """
  The issue as a run reads it: a groomed ticket's description is its ask, plan and checks
  (`plan_text/1`), so whatever a caller reads from the description is read from the plan. An issue
  that is not groomed comes back as it is.
  """
  @spec planned(issue) :: issue when issue: map()
  def planned(%{} = issue) do
    case plan_text(issue) do
      nil -> issue
      text -> Map.put(issue, :description, text)
    end
  end

  @doc """
  The ticket as a prompt shows it: a groomed ticket's ask, plan and checks, as untrusted text, else
  what `ungroomed` renders from the description.
  """
  @spec body(ticket(), (-> String.t())) :: String.t()
  def body(ticket, ungroomed) when is_function(ungroomed, 0) do
    case plan_text(ticket) do
      nil -> ungroomed.()
      text -> PromptSafety.ticket_plan_body(text)
    end
  end

  @doc """
  Checks the tests an implementer names for checks of the plan of the ticket `issue_id`: `proofs`
  is a non-empty list of `%{"step" => id, "test" => test}`, the check's id where a walkthrough's
  proof has its step's number (`"check"` names it too). A check the plan does not hold is
  refused, naming the plan's checks, as is one the plan gives to QA (`proof: qa` or `design`) and
  a test that is blank, holds a backtick or runs over one line.
  """
  @spec check_proofs(String.t(), term()) :: {:ok, [check_proof()]} | {:error, {:invalid_walkthrough_proof, String.t()}}
  def check_proofs(issue_id, [_proof | _rest] = proofs) when is_binary(issue_id) do
    checks = TicketChecks.list(issue_id)

    Enum.reduce_while(proofs, {:ok, []}, fn proof, {:ok, entries} ->
      case check_proof(proof, checks) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def check_proofs(_issue_id, _proofs), do: invalid("`proofs` must be a non-empty list of objects, each with a check's id as `step` and a `test`")

  defp check_proof(%{"test" => test} = proof, checks) when is_binary(test) do
    case Map.get(proof, "check", Map.get(proof, "step")) do
      id when is_binary(id) -> check_proof(String.trim(id), String.trim(test), checks)
      _other -> not_a_check()
    end
  end

  defp check_proof(_proof, _checks), do: not_a_check()

  defp not_a_check, do: invalid("this ticket has a plan: each proof needs the id of the check it proves as `step` (`c1`) and a string `test`")

  defp check_proof(id, test, checks) do
    case Enum.find(checks, &(&1.id == id)) do
      nil ->
        invalid("`#{id}` is not a check of this ticket's plan. Its checks are: #{Enum.map_join(checks, ", ", & &1.id)}")

      %{proof: proof} when proof in @qa_proofs ->
        invalid("check #{id} is proved by QA (`proof: #{proof}` in the plan): leave it for QA")

      _check ->
        if test == "" or String.contains?(test, ["`", "\n"]),
          do: invalid("check #{id}: the test must be one non-blank line without backticks"),
          else: {:ok, %{check_id: id, test: test}}
    end
  end

  defp invalid(message), do: {:error, {:invalid_walkthrough_proof, message}}

  @doc """
  Records what QA saw of a groomed ticket's checks: a `check.proved` (`by: qa`, or `design` for a
  check the plan proves against a design) for each step of `results` that passed and names a check
  by its id, unless a test already proves that check. `results` are a QA verdict's steps (`name`,
  `status`, `details`); `opts` are `SymphonyElixir.TicketChecks.prove/4`'s. Nothing is recorded for
  a ticket that is not groomed.
  """
  @spec record_walked(String.t() | nil, ticket(), [map()], keyword()) :: :ok
  def record_walked(repo_key, ticket, results, opts \\ []) when is_list(results) do
    for {%{state: state} = check, _number} <- numbered(ticket),
        state != :waived and not test_proved?(check),
        result = Enum.find(results, &passed?(&1, check.id)) do
      proof = %{check_id: check.id, by: if(check.proof == "design", do: "design", else: "qa"), details: details(result)}
      TicketChecks.prove(repo_key, id(ticket), proof, opts)
    end

    :ok
  end

  defp test_proved?(%{proved_by: %{by: "test"}}), do: true
  defp test_proved?(_check), do: false

  defp passed?(%{name: name, status: status}, check_id) when is_binary(name),
    do: to_string(status) == "pass" and Regex.match?(~r/(?<![\w-])#{Regex.escape(check_id)}(?![\w-])/u, name)

  defp passed?(_result, _check_id), do: false

  defp details(result) do
    case Map.get(result, :details) do
      text when is_binary(text) and text != "" -> String.slice(text, 0, 2_000)
      _none -> nil
    end
  end

  @doc """
  The checks of a groomed ticket an implementation run still owes before the handoff: the open
  ones a test or an attachment proves. None for a ticket that is not groomed.
  """
  @spec unproved(ticket()) :: [TicketChecks.check()]
  def unproved(ticket) do
    case id(ticket) do
      nil -> []
      id -> TicketChecks.open(id, proof: @handoff_proofs)
    end
  end

  @doc "Why a ticket with the `unproved/1` checks `checks` is not handed off, naming each and what proves it."
  @spec unproved_message([TicketChecks.check()]) :: String.t()
  def unproved_message(checks) do
    """
    The plan has #{length(checks)} open check(s) that a test or an attachment proves, so the ticket is not handed off yet:
    #{Enum.map_join(checks, "\n", &"- [#{&1.id}] #{one_line(&1.statement)} (proof: #{&1.proof})")}
    Prove each one, then record it: a `proof: test` check with a test of this PR \
    (`linear_record_walkthrough_proofs` with the check's id as `step` and the test), a `proof: attached` check with \
    `ticket_record` (`check.proved`, `by: attached`, and the `evidence` event that holds the file).
    A check nothing can prove this way is waived by the Conductor after coding, with its reason: \
    say which one and why in a `note` and in the workpad `Confusions`, and end the turn.\
    """
  end

  # -- a groomed ticket's checks as steps --------------------------------------------------

  # The plan's checks, each with its place in the plan (from 1): a check's step number.
  defp numbered(ticket) do
    case id(ticket) do
      nil -> []
      id -> id |> TicketChecks.list() |> Enum.with_index(1)
    end
  end

  defp walked(numbered), do: for({%{kind: "qa", state: state}, _number} = entry <- numbered, state != :waived, do: step(entry))

  defp step({check, number}), do: %{number: number, text: step_text(check), proof: %{by: :qa}, check_id: check.id}

  defp step_text(check) do
    parts = for {label, key} <- [{"State", :needs}, {"Action", :action}, {"Expect", :expect}, {"Size", :size}], value = Map.get(check, key), do: "#{label}: #{one_line(value)}"
    Enum.join(["[#{check.id}] #{one_line(check.statement)}" | parts], "\n")
  end

  # The tests recorded for the checks, laid over `steps` as a walkthrough's recorded proofs are.
  defp proved(steps, numbered, proof_check) do
    tests =
      for {%{proved_by: %{by: "test", test: test}}, number} <- numbered, is_binary(test), do: %{step: number, test: test}

    Walkthrough.with_recorded_proofs(steps, tests, proof_check)
  end

  defp walkthrough_steps(ticket, proof_check) do
    case Walkthrough.section(description(ticket)) do
      nil -> []
      text -> text |> Walkthrough.steps() |> recorded(ticket, proof_check)
    end
  end

  defp recorded(steps, ticket, proof_check),
    do: Walkthrough.with_recorded_proofs(steps, Walkthrough.recorded_proofs(id(ticket)), proof_check)

  # -- the prompt's text -----------------------------------------------------------------

  defp asks(id) do
    case for(%{text: text} <- TicketPlan.ask(id), is_binary(text), do: String.trim(text)) do
      [] -> "No ask was recorded."
      texts -> Enum.join(texts, "\n\n")
    end
  end

  defp plan_words(plan), do: plan |> Map.get(:text) |> to_string() |> String.trim()

  defp check_lines([]), do: "The plan has no check."
  defp check_lines(checks), do: Enum.map_join(checks, "\n", &check_line/1)

  defp check_line(check) do
    parts = for {label, key} <- [{"State", :needs}, {"Action", :action}, {"Expect", :expect}], value = Map.get(check, key), do: "  #{label}: #{one_line(value)}"
    Enum.join(["- [#{check.id}] #{check.kind}, proof: #{check.proof}, #{standing(check)}: #{one_line(check.statement)}" | parts], "\n")
  end

  defp standing(%{state: :proved, proved_by: %{by: by, test: test}}) when is_binary(test), do: "proved by #{by} (#{one_line(test)})"
  defp standing(%{state: :proved, proved_by: %{by: by}}), do: "proved by #{by}"
  defp standing(%{state: :waived}), do: "waived"
  defp standing(_check), do: "open"

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp plan(ticket) do
    case id(ticket) do
      nil -> nil
      id -> TicketPlan.current(id)
    end
  end

  defp id(id) when is_binary(id), do: id
  defp id(%{id: id}) when is_binary(id), do: id
  defp id(_ticket), do: nil

  defp description(%{description: description}) when is_binary(description), do: description
  defp description(_ticket), do: nil
end
