defmodule SymphonyElixir.QaAgent.PromptTerms do
  @moduledoc """
  Builds Symphony's macOS QA prompt texts from their sources and from the one definition of each
  term they state (TP-1686): the step statuses (`SymphonyElixir.QaAgent.Steps.statuses/0`), the QA
  tools (`SymphonyElixir.QaDriver.tools/0`, beside the ones Symphony serves itself) and the window
  sizes (the QA target in the playbook's settings, and each step's own setting).

  A source writes a term as a marker, filled when it is built:

  - `{{statuses}}`: the step statuses, as the list a step answers from;
  - `{{status:<word>}}`: one step status, refused when it is not in the list;
  - `{{tools}}`: the QA tools the driver serves, as the list a session has.

  A marker `build!/4` is told to keep (`keep:`) stays in the text, for the caller to fill at run
  time (the QA target's size, say). Any other marker is refused.

  The built text is then checked, and `build!/4` raises with the prompt's name and the word:

  - every `qa_*` name must be a tool the driver serves, a tool Symphony serves itself
    (`qa_verdict`), or a code a QA tool or Symphony answers with (`codes/0`); a name ending in `*`
    (`qa_worker_*`) must start at least one of them;
  - no window size (digits × digits) is written by hand: a size a prompt states comes from the QA
    target or the step's setting, which the text around the prompt renders. A quoted text (what the
    app shows, between double quotes) may hold one.

  `SymphonyElixir.QaAgent.StepPrompts` builds the step prompts with it,
  `SymphonyElixir.QaAgent.Selection` the `macos_app` playbook, and `SymphonyElixir.QaAgent`,
  `SymphonyElixir.QaAgent.Steps` and `SymphonyElixir.QaModeContract` every text they add around
  them that names a QA tool or a step status (the verdict rules, QA's jobs, the device rule, the
  follow-up for a missing verdict, the QA mode the driver gives the app), all at compile time, so a
  prompt that contradicts a definition does not compile.
  """

  alias SymphonyElixir.QaAgent.{Steps, Verdict}
  alias SymphonyElixir.QaDriver

  # The codes the QA tools and Symphony answer with, which the prompts name for what a session does
  # when it sees one.
  @codes ~w(qa_app_exited qa_element_not_found qa_elements_missing qa_helper_timeout qa_helper_unavailable) ++
           ~w(qa_host_missing_tool qa_no_app qa_no_relaunch qa_permission_missing qa_picture_not_recorded) ++
           ~w(qa_signing_identity_missing qa_signing_identity_untrusted qa_status_menu_not_opened) ++
           ~w(qa_worker_missing qa_worker_same_machine qa_worker_unreachable qa_worker_unsafe)

  @marker ~r/\{\{([a-z_]+)(?::([a-z_]+))?\}\}/
  @qa_name ~r/\bqa_[a-z0-9_]*\*?/
  @quoted ~r/"[^"]*"/
  @size ~r/\d+\s*×\s*\d+/u

  @type terms :: %{tools: [String.t()], statuses: [String.t()], symphony_tools: [String.t()], codes: [String.t()]}

  @doc """
  The terms the built-in prompts are built from: the driver's tools, the step statuses, the tools
  Symphony serves and the codes. `overrides` replaces any of them (`Steps` gives its own statuses
  while it compiles).
  """
  @spec terms(keyword()) :: terms()
  def terms(overrides \\ []) do
    %{
      tools: Keyword.get_lazy(overrides, :tools, &QaDriver.tools/0),
      statuses: Keyword.get_lazy(overrides, :statuses, &Steps.statuses/0),
      symphony_tools: Keyword.get_lazy(overrides, :symphony_tools, fn -> [Verdict.tool_name()] end),
      codes: Keyword.get(overrides, :codes, @codes)
    }
  end

  @doc "The codes the QA tools and Symphony answer with, which a prompt may name."
  @spec codes() :: [String.t()]
  def codes, do: @codes

  @doc """
  Builds the prompt `name` from `source` and `terms`: fills its markers (keeping the ones
  `opts[:keep]` names) and checks the result, raising `ArgumentError` naming the prompt and the
  word for a marker, a QA name or a window size the definitions do not allow.
  """
  @spec build!(String.t(), String.t(), terms(), keyword()) :: String.t()
  def build!(name, source, terms, opts \\ []) when is_binary(name) and is_binary(source) do
    keep = Keyword.get(opts, :keep, [])

    source
    |> fill(name, terms, keep)
    |> check_names!(name, terms)
    |> check_sizes!(name)
  end

  @doc "The step statuses, as a prompt lists them: `` `pass`, `fail` or `blocked` ``."
  @spec status_list([String.t()]) :: String.t()
  def status_list(statuses), do: or_list(statuses)

  defp fill(source, name, terms, keep) do
    Regex.replace(@marker, source, fn whole, marker, word -> marker(marker, word, whole, name, terms, keep) end)
  end

  defp marker("statuses", "", _whole, _name, terms, _keep), do: or_list(terms.statuses)
  defp marker("tools", "", _whole, _name, terms, _keep), do: Enum.map_join(terms.tools, ", ", &"`#{&1}`")

  defp marker("status", word, _whole, name, terms, _keep) when word != "" do
    if word in terms.statuses,
      do: "`#{word}`",
      else: raise(ArgumentError, "#{name} gives the step status `#{word}`, which is not one of #{or_list(terms.statuses)}")
  end

  defp marker(marker, "", whole, name, _terms, keep) do
    if marker in keep, do: whole, else: raise(ArgumentError, "#{name} has the marker #{whole}, which names no term")
  end

  defp marker(_marker, _word, whole, name, _terms, _keep), do: raise(ArgumentError, "#{name} has the marker #{whole}, which names no term")

  defp check_names!(text, name, terms) do
    known = terms.tools ++ terms.symphony_tools ++ terms.codes

    case @qa_name |> Regex.scan(text) |> List.flatten() |> Enum.uniq() |> Enum.reject(&known_name?(&1, known)) do
      [] ->
        text

      [unknown | _] ->
        raise ArgumentError,
              "#{name} names `#{unknown}`, which is not a QA tool the driver serves (#{Enum.join(terms.tools, ", ")}), " <>
                "a tool Symphony serves (#{Enum.join(terms.symphony_tools, ", ")}) or a code a QA tool answers with"
    end
  end

  defp known_name?(word, known) do
    if String.ends_with?(word, "*"),
      do: Enum.any?(known, &String.starts_with?(&1, String.trim_trailing(word, "*"))),
      else: word in known
  end

  defp check_sizes!(text, name) do
    case Regex.run(@size, Regex.replace(@quoted, text, "")) do
      nil -> text
      [size] -> raise ArgumentError, "#{name} states the window size #{size} by hand: a size comes from the QA target or the step's setting"
    end
  end

  defp or_list([one]), do: "`#{one}`"

  defp or_list(words) do
    {init, [last]} = Enum.split(words, -1)
    Enum.map_join(init, ", ", &"`#{&1}`") <> " or `#{last}`"
  end
end
