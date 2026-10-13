defmodule SymphonyElixir.HumanActions.PlainWords do
  @moduledoc """
  Finds code in a decision request, which the Director reads in plain words
  (`docs/standards/decision-writing.md`).

  `linear_request_human_action` refuses a request whose words hold any of these tokens:

  - backticks;
  - template syntax: `{%` or `%}`;
  - a path (`lib/…`, `./setup`, a link) or a file name with an extension (`foo.ex`, `*.liquid`,
    `.md`);
  - a commit hash: a run of 7 to 40 hex characters with both a digit and a letter;
  - a branch name: `auto/…` or `origin/…`.

  Ticket identifiers (`TP-891`), PR numbers (`#448`, `PR #448`), numbers and ordinary sentences
  pass. Symphony's own requests are written to pass the same check.
  """

  @typedoc "What kind of code a token is."
  @type kind :: :backticks | :template | :branch | :link | :path | :file | :hash

  @typedoc "One token of code found in a field of a request."
  @type finding :: %{field: String.t(), token: String.t(), kind: kind()}

  @backtick_span ~r/`[^`\n]*`|`/
  @template_span ~r/\{%.*?%\}|\{%|%\}/
  @branch ~r/^(?:auto|origin)\/\S+$/
  @link ~r/^[a-z][a-z0-9+.-]*:\/\/\S+$/i
  @file_name ~r/^(?<stem>[\w*.-]*)\.[A-Za-z][A-Za-z0-9]{0,9}$/
  @hash ~r/^(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}$/i
  @path_roots ~w(lib test priv docs config macos src bin scripts deps tmp .github .symphony .agents .claude Sources Tests)
  @leading ~r/^[(\[{<"'“‘]+/u
  @trailing ~r/[)\]}>"'”’,;:!?….]+$/u

  @labels %{
    backticks: "backticks",
    template: "template syntax",
    branch: "the branch name",
    link: "the link",
    path: "the path",
    file: "the file name",
    hash: "the commit hash"
  }

  @doc """
  The code in `request`'s words: its title, question, why, what waits if unanswered, what it
  unblocks, the recommendation's reason, and each option's label, effect and trade-offs. The request
  is the map `SymphonyElixir.HumanActions.Request.render_hold/2` renders; each finding names the
  field as the tool's input names it (`decision.options[0].effect`).
  """
  @spec findings(map()) :: [finding()]
  def findings(request) do
    request
    |> fields()
    |> Enum.flat_map(fn {field, text} -> Enum.map(tokens(text), fn {kind, token} -> %{field: field, token: token, kind: kind} end) end)
  end

  @doc "`:ok` when `request` holds no code, else `{:error, message}` naming each token and its field."
  @spec check(map()) :: :ok | {:error, String.t()}
  def check(request) do
    case findings(request) do
      [] -> :ok
      findings -> {:error, message(findings)}
    end
  end

  @doc "The code tokens in `text`, each with its kind, in the order found and without repeats."
  @spec tokens(String.t() | nil) :: [{kind(), String.t()}]
  def tokens(text) when is_binary(text) do
    spans =
      Enum.map(Regex.scan(@backtick_span, text), &{:backticks, hd(&1)}) ++
        Enum.map(Regex.scan(@template_span, text), &{:template, hd(&1)})

    words = for word <- String.split(text), word = trim_word(word), kind = word_kind(word), do: {kind, word}

    Enum.uniq(spans ++ words)
  end

  def tokens(_text), do: []

  @doc "The `invalid_human_action` message for `findings`: each token by field, and what to do instead."
  @spec message([finding()]) :: String.t()
  def message(findings) do
    by_field =
      findings
      |> Enum.group_by(& &1.field)
      |> Enum.sort_by(fn {_field, [first | _rest]} -> Enum.find_index(findings, &(&1 == first)) end)
      |> Enum.map_join("; ", fn {field, field_findings} ->
        "`#{field}` has " <> Enum.map_join(field_findings, ", ", &"#{@labels[&1.kind]} #{inspect(&1.token)}")
      end)

    "A decision is read by the Director, who does not read code. #{by_field}. " <>
      "Rewrite it in plain words: say what the thing does, not where it lives or what it is called in the code. " <>
      "Name a ticket by its identifier and a short name, and a PR as PR #123."
  end

  defp fields(request) do
    options = request |> Map.get(:options) |> List.wrap()

    [
      {"title", Map.get(request, :title)},
      {"decision.question", Map.get(request, :question)},
      {"why", Map.get(request, :why)},
      {"if_unanswered", Map.get(request, :if_unanswered)},
      {"unblocks", Map.get(request, :unblocks)},
      {"decision.recommendation_reason", Map.get(request, :recommendation_reason)}
    ] ++
      Enum.flat_map(Enum.with_index(options), fn {option, index} -> option_fields(option, "decision.options[#{index}]") end)
  end

  defp option_fields(%{} = option, prefix) do
    tradeoffs = option |> Map.get(:tradeoffs) |> List.wrap() |> Enum.with_index()

    [{"#{prefix}.label", Map.get(option, :label)}, {"#{prefix}.effect", Map.get(option, :effect)}] ++
      for({tradeoff, index} <- tradeoffs, do: {"#{prefix}.tradeoffs[#{index}].text", tradeoff_text(tradeoff)})
  end

  defp option_fields(option, prefix) when is_binary(option), do: [{prefix, option}]

  defp tradeoff_text(%{text: text}), do: text
  defp tradeoff_text(_tradeoff), do: nil

  # A word without the punctuation around it: quotes and brackets, and the comma or full stop that
  # ends a clause (`done.` is the word `done`).
  defp trim_word(word) do
    word
    |> String.replace("`", "")
    |> then(&Regex.replace(@leading, &1, ""))
    |> then(&Regex.replace(@trailing, &1, ""))
  end

  defp word_kind(""), do: nil

  defp word_kind(word) do
    cond do
      Regex.match?(@branch, word) -> :branch
      Regex.match?(@link, word) -> :link
      path?(word) -> :path
      file?(word) -> :file
      Regex.match?(@hash, word) -> :hash
      true -> nil
    end
  end

  # A word with a slash is a path when it reads like one: rooted (`/etc`, `./x`, `~/x`), ending in a
  # slash, deeper than one level, with a segment a word would not have (`_` or `.`), or under a
  # repository's usual top folder (`lib/…`). `and/or` and `client/server` stay words.
  defp path?(word) do
    if String.contains?(word, "/") do
      segments = String.split(word, "/")

      String.starts_with?(word, ["/", "./", "../", "~/"]) or String.ends_with?(word, "/") or length(segments) > 2 or
        Enum.any?(segments, &String.contains?(&1, ["_", ".", "*"])) or hd(segments) in @path_roots
    else
      false
    end
  end

  # A name with an extension: `foo.ex`, `*.liquid`, `.md`, `Request.render`. The extension starts
  # with a letter, so numbers (`1.5`) pass, and the name before it is empty, a wildcard, or at least
  # two characters with a letter, so `e.g.` and `i.e.` pass.
  defp file?(word) do
    case Regex.named_captures(@file_name, word) do
      %{"stem" => ""} -> true
      %{"stem" => stem} -> String.contains?(stem, "*") or (String.length(stem) >= 2 and Regex.match?(~r/[A-Za-z_]/, stem))
      nil -> false
    end
  end
end
