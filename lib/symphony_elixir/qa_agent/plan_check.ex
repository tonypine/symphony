defmodule SymphonyElixir.QaAgent.PlanCheck do
  @moduledoc """
  Symphony's own check of a stepped QA pass's plan (`SymphonyElixir.QaAgent.Steps`), before any
  session walks a step: a walked step that needs what the pass does not have is marked
  `unprovable` (`status/0`), with what it needed, and gets no session.

  It is decided from data, never from the words of a step, in two places:

    * `settings/2`, before the QA plan session: a step whose plan check's `setting` is the live
      server, on a pass that has none, or names a fixture directory the worktree does not hold;
    * `briefs/3`, once the QA plan answered and before the first walk session: each brief's
      `needs` (`needs_shape/1`), a list of objects in a fixed shape: `{"kind": "tool", "name":
      "qa_drag"}` for a QA driver tool, `{"kind": "fixture_page", "fixture": "<directory>",
      "page": "<page>"}` for a page of a committed fixture (the directory by its path in the
      checkout, or by its name among the state fixtures in `macos/Tests/Fixtures/director-app`), `{"kind": "server"}` for the live
      server. A tool the driver does not offer, a fixture directory that is absent, or the server on
      a pass without one marks the step.

  The pass's facts (`t:facts/0`) are the QA driver's tool names (`SymphonyElixir.QaDriver.tools/0`),
  whether the pass runs the live server (its `macos_app` playbook marked `live: true`,
  `SymphonyElixir.QaPolicy`), why not, and the worktree the fixtures are read from.

  A marked step reaches the verdict as a step Symphony settled (`verdict_step/1`): status
  `unprovable`, its `details` what it needed, and `needs` set, so `SymphonyElixir.QaVerification`
  tells it apart from a step an agent called unprovable.
  """

  @status "unprovable"
  @kinds ~w(tool fixture_page server)

  # Where a fixture named by its bare directory name (`update-paused`, as the QA rules and
  # docs/configuration.md name one) lives: the Director's committed state fixtures.
  @state_fixtures "macos/Tests/Fixtures/director-app"

  @typedoc "What the pass has: the driver's tools, whether it runs the live server (and why not), and its worktree."
  @type facts :: %{tools: [String.t()], live: boolean(), live_reason: String.t() | nil, worktree: Path.t()}

  @typedoc "A walked step Symphony marked: the step, and what it needed that the pass lacks, one sentence each."
  @type marked :: %{number: integer(), target: map(), needs: [String.t()]}

  @doc "The one status word for a step this pass cannot do."
  @spec status() :: String.t()
  def status, do: @status

  @doc "The kinds a brief's `needs` entry may name."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The walked steps `targets` split by their plan check's setting alone: `{kept, marked}`. A step
  set to the live server on a pass with no live server, or to a fixture directory `facts.worktree`
  does not hold, is marked.
  """
  @spec settings([map()], facts()) :: {[map()], [marked()]}
  def settings(targets, facts) do
    split(targets, &setting_needs(Map.get(&1, :setting), facts))
  end

  @doc """
  Whether a brief's `needs` is in the fixed shape: absent, or a list of objects each naming a kind
  of `kinds/0` with its fields (`name` for a tool, `fixture` for a fixture page). The error says
  what to fix, for the plan session to answer again.
  """
  @spec needs_shape(map()) :: :ok | {:error, String.t()}
  def needs_shape(brief) when is_map(brief) do
    case Map.fetch(brief, "needs") do
      :error -> :ok
      {:ok, needs} when is_list(needs) -> if Enum.all?(needs, &need?/1), do: :ok, else: {:error, shape_error()}
      {:ok, _other} -> {:error, shape_error()}
    end
  end

  def needs_shape(_brief), do: {:error, shape_error()}

  defp shape_error do
    ~s(each brief's `needs` must be a list of objects: {"kind": "tool", "name": "<qa_ tool>"}, ) <>
      ~s({"kind": "fixture_page", "fixture": "<directory: its path in the checkout or its name>", "page": "<page>"} ) <>
      ~s(or {"kind": "server"})
  end

  defp need?(%{"kind" => "tool", "name" => name}), do: text?(name)
  defp need?(%{"kind" => "fixture_page", "fixture" => fixture} = need), do: text?(fixture) and page?(Map.get(need, "page"))
  defp need?(%{"kind" => "server"}), do: true
  defp need?(_need), do: false

  defp page?(nil), do: true
  defp page?(page), do: text?(page)

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  The walked steps `targets` split by the `needs` of the plan's brief for each (`briefs`, the plan's
  `walk`): `{kept, marked}`. Each need is checked against `facts`; a step with no brief, or a brief
  with no `needs`, is kept.
  """
  @spec briefs([map()], [map()], facts()) :: {[map()], [marked()]}
  def briefs(targets, briefs, facts) do
    split(targets, fn target ->
      briefs
      |> Enum.find(&(brief_number(&1) == target.number))
      |> brief_needs()
      |> Enum.flat_map(&unmet(&1, facts))
    end)
  end

  @doc """
  The step a marked one is in the verdict: `unprovable`, with what it needed in `details`, and
  `needs` so it is told apart from an agent's.
  """
  @spec verdict_step(marked()) :: map()
  def verdict_step(%{target: target, needs: needs}) do
    %{name: step_name(target), status: @status, details: details(needs), evidence: [], needs: needs}
  end

  @doc "The verdict's name for walked step `target`: its walkthrough step's number, and its plan check's id when it has one."
  @spec step_name(map()) :: String.t()
  def step_name(%{check_id: check_id, number: number}) when is_binary(check_id), do: "Walkthrough step #{number} (check #{check_id})"
  def step_name(%{number: number}), do: "Walkthrough step #{number}"

  @doc """
  Whether a verdict step `name` written by the review stands for walked step `target`: Symphony's
  own name for it, or a name that opens with its walkthrough step's number (`Step 1`,
  `Walkthrough step 1: ...`). A marked step keeps one entry in the verdict, the one Symphony settled.
  """
  @spec names_step?(term(), map()) :: boolean()
  def names_step?(name, %{number: number} = target) when is_binary(name) do
    name = String.trim(name)

    String.downcase(name) == String.downcase(step_name(target)) or
      Regex.match?(~r/^(walkthrough\s+)?step\s*#?\s*#{number}(?!\d)/i, name)
  end

  def names_step?(_name, _target), do: false

  @doc "What a marked step needed, as its `details` read."
  @spec details([String.t()]) :: String.t()
  def details(needs), do: "Symphony marked it before any session: it needs " <> Enum.join(needs, "; and ") <> "."

  defp split(targets, needs_of) do
    Enum.reduce(targets, {[], []}, fn target, {kept, marked} ->
      case needs_of.(target) do
        [] -> {kept ++ [target], marked}
        needs -> {kept, marked ++ [%{number: target.number, target: target, needs: Enum.uniq(needs)}]}
      end
    end)
  end

  defp setting_needs(%{source: "live"}, %{live: false} = facts), do: [no_server(facts)]
  defp setting_needs(%{source: "fixture", fixture: fixture}, facts) when is_binary(fixture), do: missing_fixture(fixture, nil, facts)
  defp setting_needs(_setting, _facts), do: []

  defp brief_needs(%{"needs" => needs}) when is_list(needs), do: Enum.filter(needs, &need?/1)
  defp brief_needs(_brief), do: []

  defp unmet(%{"kind" => "tool", "name" => name}, facts) do
    name = String.trim(name)
    if name in facts.tools, do: [], else: ["the QA tool `#{name}`, which the QA driver does not have"]
  end

  defp unmet(%{"kind" => "fixture_page", "fixture" => fixture} = need, facts), do: missing_fixture(fixture, Map.get(need, "page"), facts)
  defp unmet(%{"kind" => "server"}, %{live: false} = facts), do: [no_server(facts)]
  defp unmet(%{"kind" => "server"}, _facts), do: []

  defp no_server(%{live_reason: reason}) when is_binary(reason), do: "the live server, which this pass does not run (#{reason})"
  defp no_server(_facts), do: "the live server, which this pass does not run"

  defp missing_fixture(fixture, page, facts) do
    fixture = fixture |> String.trim() |> String.trim_trailing("/")

    if fixture_dir?(facts.worktree, fixture),
      do: [],
      else: ["the fixture `#{fixture}`#{page_note(page)}, which this pass's worktree does not hold"]
  end

  # A fixture is named by its path in the checkout (`macos/Tests/Fixtures/director-app/running`)
  # or by its directory's name among the state fixtures (`running`).
  defp fixture_dir?(worktree, fixture) do
    File.dir?(Path.join(worktree, fixture)) or File.dir?(Path.join([worktree, @state_fixtures, fixture]))
  end

  defp page_note(page) when is_binary(page), do: " (page #{String.trim(page)})"
  defp page_note(_page), do: ""

  defp brief_number(%{"step" => number}) when is_integer(number), do: number

  defp brief_number(%{"step" => number}) when is_binary(number) do
    case Integer.parse(String.trim(number)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp brief_number(_brief), do: nil
end
