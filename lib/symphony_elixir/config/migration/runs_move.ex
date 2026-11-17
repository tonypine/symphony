defmodule SymphonyElixir.Config.Migration.RunsMove do
  @moduledoc """
  What the move from the `agent` section to `execution` and `runs` makes of a parsed
  `symphony.yml`: the document the rewritten file must read as.

  The old file named one harness for every run (`agent.runtime`, `agent.command`), with the
  model, effort and provider beside it, per run kind under `agent.run_profiles`, and again in
  `code_review`, `auto_review` and each `repositories[].agent`. The new file names each
  harness's command once under `execution.harnesses` and what every kind of run starts with
  under `runs` (`SymphonyElixir.Config.Runs`). Nothing is built in there, so this fills in what
  the old file left to a default:

    * the provider: `agent.provider`, else `anthropic` for claude and `openai` for codex;
    * the model: `agent.model`, else the model the command passed (`--model`, or codex's
      `model=` override), which leaves the command;
    * the small model claude calls in the background: `agent.small_model`, else Anthropic's
      own small model for an `anthropic` run and the run's model for any other provider, which
      is what those runs did.

  A run with no model anywhere cannot be moved: `document/1` says which key to set.
  """

  alias SymphonyElixir.Config.Runs

  @run_keys ["runtime", "command", "model", "effort", "provider", "small_model", "run_profiles"]
  @section_run_keys ["runtime", "command", "model", "effort"]
  @retired_kinds ["close_out", "final_verification", "acceptance_gate", "pre_push_review"]
  @providers %{"claude" => "anthropic", "codex" => "openai"}
  @anthropic_small_model "claude-haiku-5-5"

  @doc "The keys of the `agent` section that move to `runs` and `execution.harnesses`."
  @spec run_keys() :: [String.t()]
  def run_keys, do: @run_keys

  @doc "The keys of `code_review` and `auto_review` that move to `runs.code_review` and `runs.qa`."
  @spec section_run_keys() :: [String.t()]
  def section_run_keys, do: @section_run_keys

  @doc "Whether `document` still has an `agent` section, or a repository's `agent` block, to move."
  @spec needed?(map()) :: boolean()
  def needed?(document) when is_map(document) do
    is_map(document["agent"]) or Enum.any?(repositories(document), &(is_map(&1) and is_map(&1["agent"])))
  end

  @doc """
  `document` with its `agent` section moved, or the reason it cannot be: a message that names
  the key to set.
  """
  @spec document(map()) :: {:ok, map()} | {:error, String.t()}
  def document(document) when is_map(document) do
    agent = section(document, "agent")

    with {:ok, default, command} <- default_entry(agent),
         {:ok, code_review} <- section_entry(section(document, "code_review"), "code_review", default),
         {:ok, qa} <- section_entry(section(document, "auto_review"), "auto_review", default) do
      runs =
        agent
        |> profiles()
        |> merge_entry("code_review", code_review)
        |> merge_entry("qa", qa)
        |> Map.put(Runs.default(), default)
        |> put_small_models(nil, agent["small_model"])

      {:ok,
       document
       |> Map.delete("agent")
       |> Map.put("execution", execution(agent, default["harness"], command, runs))
       |> Map.put("runs", runs)
       |> update_section("code_review")
       |> update_section("auto_review")
       |> update_repositories(runs, agent["small_model"])}
    end
  end

  defp section(document, key) do
    case Map.get(document, key) do
      %{} = section -> section
      _other -> %{}
    end
  end

  defp repositories(document) do
    case Map.get(document, "repositories") do
      repositories when is_list(repositories) -> repositories
      _other -> []
    end
  end

  # `runs.default`: what every run started with, and the harness's command without its model
  # and effort flags.
  defp default_entry(agent) do
    harness = agent["runtime"]
    {command, flag_model, flag_effort} = split_command(agent["command"], harness)
    model = agent["model"] || flag_model

    cond do
      not is_map_key(@providers, harness) ->
        {:error, "`agent.runtime` must be claude or codex to move it to `runs.default.harness`"}

      is_nil(command) ->
        {:error, "`agent.command` must be set to move it to `execution.harnesses.#{harness}.command`"}

      is_nil(model) ->
        {:error, "no model is set for the runs; set `agent.model`, which becomes `runs.default.model`"}

      true ->
        entry =
          %{"harness" => harness, "provider" => agent["provider"] || @providers[harness], "model" => model}
          |> put_set("effort", agent["effort"] || flag_effort)

        {:ok, entry, command}
    end
  end

  # A section's own run settings, as its run kind's entry. A harness other than the default
  # one brings its own provider, and must name a model.
  defp section_entry(section, name, default) do
    harness = section["runtime"]
    other_harness = if is_binary(harness) and harness != default["harness"], do: harness
    {command, flag_model, flag_effort} = split_command(section["command"], harness || default["harness"])
    model = section["model"] || flag_model

    with :ok <- check_other_harness(other_harness, model, name) do
      {:ok,
       %{}
       |> put_set("harness", other_harness)
       |> put_set("provider", other_harness && @providers[other_harness])
       |> put_set("command", command)
       |> put_set("model", model)
       |> put_set("effort", section["effort"] || flag_effort)}
    end
  end

  defp check_other_harness(nil, _model, _name), do: :ok

  defp check_other_harness(harness, _model, name) when not is_map_key(@providers, harness),
    do: {:error, "`#{name}.runtime` must be claude or codex to move it to `runs`"}

  defp check_other_harness(harness, nil, name), do: {:error, "`#{name}` runs #{harness} with no model; set `#{name}.model`"}
  defp check_other_harness(_harness, _model, _name), do: :ok

  # The run kinds `agent.run_profiles` set, without the kinds that no longer run.
  defp profiles(%{"run_profiles" => %{} = profiles}) do
    profiles
    |> Map.drop(@retired_kinds)
    |> Map.new(fn {kind, profile} -> {to_string(kind), profile_entry(profile)} end)
  end

  defp profiles(_agent), do: %{}

  defp profile_entry(%{} = profile) do
    profile
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["model", "effort", "provider"])
  end

  defp profile_entry(_profile), do: %{}

  defp merge_entry(runs, _kind, entry) when map_size(entry) == 0, do: runs
  defp merge_entry(runs, kind, entry), do: Map.update(runs, kind, entry, &Map.merge(&1, entry))

  # A claude run on a provider other than Anthropic's sent its background calls to
  # `agent.small_model`, else to its own model. An entry that picks such a provider or its
  # model says so itself; `inherited` are the entries a repository's block resolves over.
  defp put_small_models(runs, inherited, small_model) do
    Map.new(runs, fn {name, entry} ->
      resolved = resolved(runs, inherited, name)
      own? = name == Runs.default() or is_map_key(entry, "provider") or is_map_key(entry, "model")

      if own? and resolved["harness"] == "claude" and resolved["provider"] not in [nil, "anthropic"] and is_binary(resolved["model"]) do
        {name, Map.put(entry, "small_model", small_model || resolved["model"])}
      else
        {name, entry}
      end
    end)
  end

  defp resolved(runs, inherited, name) do
    inherited = inherited || %{}

    [Map.get(inherited, Runs.default(), %{}), Map.get(inherited, name, %{}), Map.get(runs, Runs.default(), %{}), Map.get(runs, name, %{})]
    |> Enum.reduce(&Map.merge(&2, &1))
  end

  # The `execution` section: `agent` without its run keys, with the harness map, and the
  # sandbox and MCP keys that named a harness a runtime.
  defp execution(agent, harness, command, runs) do
    agent
    |> Map.drop(@run_keys)
    |> Map.put("harnesses", harnesses(harness, command, runs))
    |> rename_in(["permissions", "outer_sandbox"], "runtime", "kind")
    |> rename_mcp_servers()
  end

  defp harnesses(harness, command, runs) do
    claude_on_anthropic? =
      Enum.any?(Map.keys(runs), fn name ->
        resolved = resolved(runs, nil, name)
        resolved["harness"] == "claude" and resolved["provider"] == "anthropic"
      end)

    %{harness => %{"command" => command}}
    |> then(fn harnesses ->
      if claude_on_anthropic?,
        do: Map.update(harnesses, "claude", %{"small_model" => %{"anthropic" => @anthropic_small_model}}, &Map.put(&1, "small_model", %{"anthropic" => @anthropic_small_model})),
        else: harnesses
    end)
  end

  defp rename_in(map, [], from, to) when is_map(map) do
    case Map.pop(map, from, :unset) do
      {:unset, map} -> map
      {value, map} -> Map.put(map, to, value)
    end
  end

  defp rename_in(map, [key | path], from, to) when is_map(map) do
    case Map.get(map, key) do
      %{} = child -> Map.put(map, key, rename_in(child, path, from, to))
      _other -> map
    end
  end

  defp rename_mcp_servers(execution) do
    case get_in(execution, ["mcp", "servers"]) do
      %{} = servers ->
        servers = Map.new(servers, fn {name, server} -> {name, if(is_map(server), do: rename_in(server, [], "runtimes", "harnesses"), else: server)} end)
        put_in(execution, ["mcp", "servers"], servers)

      _other ->
        execution
    end
  end

  defp update_section(document, key) do
    case Map.get(document, key) do
      %{} = section -> Map.put(document, key, Map.drop(section, @section_run_keys))
      _other -> document
    end
  end

  defp update_repositories(document, runs, small_model) do
    case Map.get(document, "repositories") do
      repositories when is_list(repositories) ->
        Map.put(document, "repositories", Enum.map(repositories, &repository(&1, runs, small_model)))

      _other ->
        document
    end
  end

  defp repository(%{"agent" => agent} = repository, runs, small_model) do
    repository = Map.delete(repository, "agent")

    case repository_runs(agent, runs, small_model) do
      repository_runs when map_size(repository_runs) == 0 -> repository
      repository_runs -> Map.put(repository, "runs", repository_runs)
    end
  end

  defp repository(repository, _runs, _small_model), do: repository

  @doc "A repository's `agent` block as its `runs` block; `runs` are the operator's, which it resolves over."
  @spec repository_runs(term(), Runs.t(), String.t() | nil) :: Runs.t()
  def repository_runs(%{} = agent, runs, small_model) do
    default = profile_entry(agent)

    agent
    |> profiles()
    |> then(fn kinds -> if map_size(default) == 0, do: kinds, else: Map.put(kinds, Runs.default(), default) end)
    |> put_repository_small_models(runs, small_model)
  end

  def repository_runs(_agent, _runs, _small_model), do: %{}

  defp put_repository_small_models(repository_runs, runs, small_model) do
    Map.new(repository_runs, fn {name, entry} ->
      resolved = Map.merge(resolved(runs, nil, name), Map.merge(Map.get(repository_runs, Runs.default(), %{}), entry))

      if resolved["harness"] == "claude" and resolved["provider"] != "anthropic" and (is_map_key(entry, "provider") or is_map_key(entry, "model")) do
        {name, Map.put(entry, "small_model", small_model || resolved["model"])}
      else
        {name, entry}
      end
    end)
  end

  defp put_set(map, _key, nil), do: map
  defp put_set(map, key, value), do: Map.put(map, key, value)

  @claude_flag ~r/(?:^|\s)--(model|effort)(?:=|\s+)(\S+)/
  @codex_model ~r/(?:^|\s)(?:--config|-c)\s+(['"]?)model=\\?"?([^'"\s\\]+)\\?"?\1/

  @doc """
  A command without the model and effort it passed, and those two: claude's `--model` and
  `--effort`, and codex's `model=` override. Codex's `model_reasoning_effort` stays in its
  command, where codex reads it.
  """
  @spec split_command(term(), String.t() | nil) :: {String.t() | nil, String.t() | nil, String.t() | nil}
  def split_command(command, harness) when is_binary(command) do
    case harness do
      "codex" ->
        model = with [_all, _quote, model] <- Regex.run(@codex_model, command), do: model
        {tidy(Regex.replace(@codex_model, command, "")), model, nil}

      _claude ->
        flags = Map.new(Regex.scan(@claude_flag, command), fn [_all, flag, value] -> {flag, value} end)
        {tidy(Regex.replace(@claude_flag, command, "")), flags["model"], flags["effort"]}
    end
  end

  def split_command(_command, _harness), do: {nil, nil, nil}

  defp tidy(command) do
    case command |> String.split() |> Enum.join(" ") do
      "" -> nil
      command -> command
    end
  end
end
