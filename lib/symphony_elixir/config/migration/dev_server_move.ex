defmodule SymphonyElixir.Config.Migration.DevServerMove do
  @moduledoc """
  Carries a settings file from the two descriptions of a project's own server to the one
  `verification.dev_server`, with its `runs` rule (TP-1663).

  Before, the server was described twice: `verification.dev_server`, which a playbook ran on every
  pass with `dev_server: true`, and a `macos_app` playbook's `live` block, which a pass the plan
  marked live ran. Now `verification.dev_server` is the only description and `runs` says when it
  runs (`Schema.Verification.DevServer`):

  - a `macos_app` playbook with `live` gives its commands, health check and timeout to
    `verification.dev_server` (with the defaults `live` had), and `runs: live_qa_pass`; the
    commands `verification.dev_server` held before go, as a file with both had two recipes and the
    live one is the server Symphony ran on the QA host;
  - a `macos_app` playbook with `dev_server: true` gives `runs: every_qa_pass`;
  - every playbook's `dev_server` and `live` keys go; `dev_server_port` stays.

  `migrate/1` is the change on a parsed, string-keyed map: `SymphonyElixir.Config.RepoWorkflowSchema`
  applies it when a repository's `WORKFLOW.md` loads, in memory, so an older file (Job Search Hub's,
  or an open ticket's branch) keeps working with no edit. `plan/4` rewrites a `symphony.yml`'s text
  the same way, for `SymphonyElixir.Config.Migration`.
  """

  alias SymphonyElixir.Config.LineEditor
  alias SymphonyElixir.Config.Migration.Lines

  @ticket "TP-1663"
  @playbook_keys ~w(dev_server live)
  @recipe_keys ~w(build_cmd start_cmd health_check_url health_timeout_ms)
  @new_keys @recipe_keys ++ ["runs"]
  @live_health_check_url "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
  @live_health_timeout_ms 600_000

  @doc "Whether a playbook of `document` still has `dev_server` or `live`."
  @spec needed?(map()) :: boolean()
  def needed?(document) when is_map(document) do
    document
    |> playbooks()
    |> Enum.any?(fn {_kind, playbook} -> is_map(playbook) and Enum.any?(@playbook_keys, &Map.has_key?(playbook, &1)) end)
  end

  @doc "`document` (string keys) with the server in `verification.dev_server` and its `runs` rule."
  @spec migrate(map()) :: map()
  def migrate(document) when is_map(document) do
    if needed?(document), do: do_migrate(document), else: document
  end

  defp do_migrate(document) do
    playbooks = playbooks(document)
    macos_app = Map.get(playbooks, "macos_app")
    macos_app = if is_map(macos_app), do: macos_app, else: %{}

    document =
      case server(macos_app) do
        nil -> document
        server -> put_dev_server(document, server)
      end

    cleaned = Map.new(playbooks, fn {kind, playbook} -> {kind, if(is_map(playbook), do: Map.drop(playbook, @playbook_keys), else: playbook)} end)
    put_in_map(document, ["auto_review", "playbooks"], cleaned)
  end

  # What the `macos_app` playbook says of the server: a `live` block's recipe and rule, or the rule
  # alone for `dev_server: true`.
  defp server(%{"live" => live}) when is_map(live) do
    live = Map.new(live, fn {key, value} -> {to_string(key), value} end)

    %{
      "build_cmd" => Map.get(live, "build_cmd"),
      "start_cmd" => Map.get(live, "start_cmd"),
      "health_check_url" => Map.get(live, "health_check_url") || @live_health_check_url,
      "health_timeout_ms" => Map.get(live, "health_timeout_ms") || @live_health_timeout_ms,
      "runs" => "live_qa_pass"
    }
  end

  defp server(%{"dev_server" => true}), do: %{"runs" => "every_qa_pass"}
  defp server(_playbook), do: nil

  defp put_dev_server(document, %{"runs" => "live_qa_pass"} = server) do
    dev_server = document |> get_map(["verification", "dev_server"]) |> Map.drop(@recipe_keys)
    recipe = server |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    put_in_map(document, ["verification", "dev_server"], Map.merge(dev_server, recipe))
  end

  defp put_dev_server(document, server) do
    put_in_map(document, ["verification", "dev_server"], Map.merge(get_map(document, ["verification", "dev_server"]), server))
  end

  @doc """
  `text` (a `symphony.yml`, `document` parsed) rewritten as `migrate/1` says, touching only the
  lines of the keys that move, with a comment naming the ticket where each was and `backup`, the
  file as it was. An error names a key the rewrite could not move (one written inside `{...}`).
  """
  @spec plan(String.t(), map(), String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | {:error, {:not_migrated, [{String.t(), pos_integer() | nil}]}}
  def plan(text, document, backup, version) when is_binary(text) and is_map(document) do
    expected = migrate(document)
    lines = String.split(text, "\n")
    entries = Lines.key_entries(lines)
    note = note(document, expected, version)
    comment = "# Symphony: #{note} (#{@ticket}). The file as it was: #{backup}."

    removed = removed_entries(entries, document, expected)
    edits = removal_edits(removed, lines, comment) ++ emptied_parents(removed, entries, lines)
    migrated = lines |> Lines.apply_edits(edits) |> Enum.join("\n")

    with {:ok, migrated} <- put_server(migrated, document, expected),
         {:ok, ^expected} <- YamlElixir.read_from_string(migrated) do
      {:ok, migrated, [note]}
    else
      _not_moved -> {:error, {:not_migrated, unmoved(entries, document)}}
    end
  end

  defp note(document, expected, version) do
    previous = get_in_map(document, ["verification", "dev_server", "runs"])

    case get_in_map(expected, ["verification", "dev_server", "runs"]) do
      runs when runs != nil and runs != previous ->
        "v#{version} described the project's server once, in `verification.dev_server`, which now runs on `runs: #{runs}`" <>
          dropped_recipe(document, expected)

      _unchanged ->
        "v#{version} removed the macos_app playbook's `dev_server` and `live` keys: `verification.dev_server.runs` says when the server runs"
    end
  end

  # A file with both recipes keeps the live one: the other's start command is named as dropped.
  defp dropped_recipe(document, expected) do
    case {get_in_map(document, ["verification", "dev_server", "start_cmd"]), get_in_map(expected, ["verification", "dev_server", "start_cmd"])} do
      {old, new} when is_binary(old) and old != new -> "; the commands it held before (`#{old}`) are dropped"
      _same -> ""
    end
  end

  # The playbook keys that go, and an old command of `verification.dev_server` the live recipe
  # does not set (its `build_cmd`, say). The others are overwritten where they stand.
  defp removed_entries(entries, document, expected) do
    server = get_map(expected, ["verification", "dev_server"])

    Enum.filter(entries, fn entry ->
      case String.split(entry.path, ".") do
        ["auto_review", "playbooks", _kind, key] -> key in @playbook_keys
        ["verification", "dev_server", key] -> key in @recipe_keys and Map.has_key?(get_map(document, ["verification", "dev_server"]), key) and not Map.has_key?(server, key)
        _other -> false
      end
    end)
  end

  defp removal_edits(removed, lines, comment) do
    removed
    |> Enum.with_index()
    |> Enum.map(fn {entry, position} ->
      insert = if position == 0, do: [String.duplicate(" ", entry.column) <> comment], else: []
      {entry.index, Lines.block_length(lines, entry), insert}
    end)
  end

  # A playbook whose every key goes is left as `{}`, so it still reads as the empty map `migrate/1`
  # makes. `verification.dev_server` gets the new keys written into it instead.
  defp emptied_parents(removed, entries, lines) do
    removed_indexes = MapSet.new(removed, & &1.index)

    for parent <- entries,
        String.starts_with?(parent.path, "auto_review."),
        not MapSet.member?(removed_indexes, parent.index),
        children = Enum.filter(entries, &(&1.parent == parent.index)),
        children != [],
        Enum.all?(children, &MapSet.member?(removed_indexes, &1.index)) do
      {parent.index, 1, [String.trim_trailing(Enum.at(lines, parent.index)) <> " {}"]}
    end
  end

  # Each key of `verification.dev_server` the move sets, written where it belongs.
  defp put_server(text, document, expected) do
    before = get_map(document, ["verification", "dev_server"])
    server = get_map(expected, ["verification", "dev_server"])

    @new_keys
    |> Enum.filter(&(Map.has_key?(server, &1) and Map.get(server, &1) != Map.get(before, &1)))
    |> Enum.reduce_while({:ok, text}, fn key, {:ok, text} ->
      case LineEditor.put(text, ["verification", "dev_server", key], Jason.encode!(Map.fetch!(server, key))) do
        {:ok, text} -> {:cont, {:ok, text}}
        {:error, _reason} -> {:halt, :not_written}
      end
    end)
  end

  defp unmoved(entries, document) do
    lines = Map.new(entries, &{&1.path, &1.index + 1})

    for {kind, playbook} <- document |> playbooks() |> Enum.sort(), is_map(playbook), key <- @playbook_keys, Map.has_key?(playbook, key) do
      path = "auto_review.playbooks.#{kind}.#{key}"
      {path, Map.get(lines, path) || Map.get(lines, "auto_review.playbooks.#{kind}") || Map.get(lines, "auto_review.playbooks") || Map.get(lines, "auto_review")}
    end
  end

  defp playbooks(document) do
    case get_in_map(document, ["auto_review", "playbooks"]) do
      %{} = playbooks -> playbooks
      _none -> %{}
    end
  end

  defp get_in_map(value, []), do: value
  defp get_in_map(%{} = map, [key | path]), do: get_in_map(Map.get(map, key), path)
  defp get_in_map(_value, _path), do: nil

  defp get_map(document, path) do
    case get_in_map(document, path) do
      %{} = map -> map
      _none -> %{}
    end
  end

  defp put_in_map(map, [key], value), do: Map.put(map, key, value)
  defp put_in_map(map, [key | path], value), do: Map.put(map, key, put_in_map(get_map(map, [key]), path, value))
end
