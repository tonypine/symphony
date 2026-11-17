defmodule SymphonyElixir.Config.Runs do
  @moduledoc """
  The `runs:` section of `symphony.yml`, a repository's `runs:` block, and the
  `execution.harnesses` map they launch with.

  An entry names what a kind of run starts with: its `harness`, the `provider` that serves its
  model, the `model`, and optionally an `effort`, a `small_model` and a `command` of its own.
  `default` is an entry among the run kinds, and the only defaulting there is. Each field
  resolves on its own, first match wins:

      repositories[].runs.<kind> → repositories[].runs.default → runs.<kind> → runs.default

  Nothing is built in: a run that resolves no harness, provider or model is an error that
  names the entry (`resolve/4`), and `symphony.yml` does not load.

  An entry may list `fallbacks`: alternatives tried in order when its provider cannot take a
  new run (paused, held by a usage limit, or at its reserve). Each sets what differs (`harness`,
  `provider`, `model`, `effort`, `small_model`); one that changes the harness or the provider
  names its own model. The list is taken whole from the first entry that sets one
  (`candidates/4`).

  A harness's command comes from `execution.harnesses.<harness>.command`, unless the run kind's
  own entry sets `command`. A harness that calls a small model in the background
  (`SymphonyElixir.Harnesses.small_model?/1`) needs one for the run's provider: the entry's
  `small_model`, else `execution.harnesses.<harness>.small_model.<provider>`.
  """

  alias SymphonyElixir.{Harnesses, RunKind}

  defmodule Run do
    @moduledoc """
    What one kind of run starts with, every field resolved. `fallback` is nil for the entry's
    own choice, and the place in its `fallbacks` list for an alternative.
    """

    @enforce_keys [:kind, :harness, :command, :provider, :model]
    defstruct [:kind, :harness, :command, :provider, :model, :effort, :small_model, :fallback]

    @type t :: %__MODULE__{
            kind: RunKind.t(),
            harness: String.t(),
            command: String.t(),
            provider: String.t(),
            model: String.t(),
            effort: String.t() | nil,
            small_model: String.t() | nil,
            fallback: non_neg_integer() | nil
          }
  end

  @typedoc "One entry's set fields, by name."
  @type entry :: %{optional(String.t()) => String.t()}
  @typedoc "A `runs:` block: `default` and the run kinds it sets."
  @type t :: %{optional(String.t()) => entry()}
  @typedoc "A repository's block with its config key, `repositories[<key>].runs`."
  @type repo :: {String.t(), t()}
  @typedoc "The `execution.harnesses` map: each harness's command and small models by provider."
  @type harnesses :: %{optional(String.t()) => harness()}
  @typedoc "One harness's command, and the small model it calls in the background, by provider."
  @type harness :: %{command: String.t() | nil, small_model: %{optional(String.t()) => String.t()}}

  @default "default"
  @kinds Map.new(RunKind.kinds(), &{Atom.to_string(&1), &1})
  @efforts ["low", "medium", "high", "xhigh", "max"]
  @entry_keys ["harness", "provider", "model", "effort", "small_model", "command"]
  @fallback_keys ["harness", "provider", "model", "effort", "small_model"]
  @harness_keys ["command", "small_model"]
  # A model or effort flag in a command would be given twice: the run's entry sets both.
  @entry_flags ["--model", "--effort"]

  @doc "The entry name every run kind falls back to."
  @spec default() :: String.t()
  def default, do: @default

  @doc "The fields an entry may set."
  @spec entry_keys() :: [String.t()]
  def entry_keys, do: @entry_keys

  @doc "The effort levels an entry may set."
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  @doc """
  Parses a `runs:` block read from YAML. `path` is its config key (`runs`, or
  `repositories[<key>].runs`), which every error message starts with.
  """
  @spec parse(term(), String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(nil, _path), do: {:ok, %{}}

  def parse(%{} = raw, path) do
    {runs, errors} =
      raw
      |> Enum.sort_by(fn {name, _entry} -> to_string(name) end)
      |> Enum.reduce({%{}, []}, fn {name, entry}, {runs, errors} ->
        name = to_string(name)

        case parse_entry(name, entry, "#{path}.#{name}") do
          {:ok, entry} -> {Map.put(runs, name, entry), errors}
          {:error, entry_errors} -> {runs, errors ++ entry_errors}
        end
      end)

    if errors == [], do: {:ok, runs}, else: {:error, errors}
  end

  def parse(_raw, path), do: {:error, ["#{path} must be a map of run kinds"]}

  @doc "Parses the `execution.harnesses` map read from YAML."
  @spec parse_harnesses(term()) :: {:ok, harnesses()} | {:error, [String.t()]}
  def parse_harnesses(nil), do: {:ok, %{}}

  def parse_harnesses(%{} = raw) do
    {harnesses, errors} =
      raw
      |> Enum.sort_by(fn {id, _harness} -> to_string(id) end)
      |> Enum.reduce({%{}, []}, fn {id, harness}, {harnesses, errors} ->
        id = to_string(id)

        case parse_harness(id, harness, "execution.harnesses.#{id}") do
          {:ok, harness} -> {Map.put(harnesses, id, harness), errors}
          {:error, harness_errors} -> {harnesses, errors ++ harness_errors}
        end
      end)

    if errors == [], do: {:ok, harnesses}, else: {:error, errors}
  end

  def parse_harnesses(_raw), do: {:error, ["execution.harnesses must be a map of harnesses"]}

  @doc """
  What a run of `kind` starts with. `repo` is the routed repository's block as
  `{config key, runs}`, or nil for none. Each error names the entry to edit.
  """
  @spec resolve(repo() | nil, t(), harnesses(), RunKind.t() | String.t()) :: {:ok, Run.t()} | {:error, [String.t()]}
  def resolve(repo, runs, harnesses, kind) do
    kind = to_string(kind)
    own_command = own_command(repo, runs, kind)
    resolve_layers(layers(repo, runs, kind), own_command, harnesses, kind, entry_path(repo, kind), nil)
  end

  @typedoc "What `candidates/4` returns: the runs in order, or the errors that name what to edit."
  @type candidates :: {:ok, [Run.t()]} | {:error, [String.t()]}

  @doc """
  The entry's own choice for a run of `kind`, then its fallbacks in order. Every one must
  resolve, so an error names the entry or the fallback to edit.
  """
  @spec candidates(repo() | nil, t(), harnesses(), RunKind.t() | String.t()) :: candidates()
  def candidates(repo, runs, harnesses, kind) do
    kind = to_string(kind)

    with {:ok, run} <- resolve(repo, runs, harnesses, kind) do
      context = %{run: run, own_command: own_command(repo, runs, kind), harnesses: harnesses, kind: kind}

      repo
      |> layers(runs, kind)
      |> field("fallbacks")
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {fallback, index} -> resolve_fallback(fallback, context, "#{entry_path(repo, kind)}.fallbacks[#{index}]", index) end)
      |> collect([run])
    end
  end

  defp collect(results, found) do
    case for({:error, errors} <- results, error <- errors, do: error) do
      [] -> {:ok, found ++ for({:ok, run} <- results, do: run)}
      errors -> {:error, errors}
    end
  end

  # A fallback is the entry's own choice with what it sets on top. One that leaves the harness
  # and the provider keeps the entry's command and small model; one that changes either names
  # its model and takes the new harness's command and small model.
  defp resolve_fallback(fallback, %{run: %Run{} = run} = context, path, index) do
    harness = Map.get(fallback, "harness", run.harness)
    same? = harness == run.harness and Map.get(fallback, "provider", run.provider) == run.provider

    base =
      %{"harness" => run.harness, "provider" => run.provider, "effort" => run.effort}
      |> Map.merge(if(same?, do: %{"model" => run.model, "small_model" => run.small_model}, else: %{}))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    own_command = if harness == run.harness, do: context.own_command
    resolve_layers([fallback, base], own_command, context.harnesses, context.kind, path, index)
  end

  defp resolve_layers(layers, own_command, harnesses, kind, entry, fallback) do
    with {:ok, harness} <- required(layers, "harness", entry),
         {:ok, provider} <- required(layers, "provider", entry),
         {:ok, model} <- required(layers, "model", entry),
         :ok <- supported(harness, provider, entry),
         {:ok, command} <- command(own_command, harnesses, harness, entry),
         {:ok, small_model} <- small_model(layers, harnesses, harness, provider, entry) do
      {:ok,
       %Run{
         kind: Map.fetch!(@kinds, kind),
         harness: harness,
         command: command,
         provider: provider,
         model: model,
         effort: field(layers, "effort"),
         small_model: small_model,
         fallback: fallback
       }}
    end
  end

  @doc """
  The config key that sets `field` for a run of `kind`, for messages that tell the operator what
  to change: `repositories[web].runs.landing.model`, or `runs.default.model`. Nil when no entry
  sets it.
  """
  @spec key(repo() | nil, t(), RunKind.t() | String.t(), String.t()) :: String.t() | nil
  def key(repo, runs, kind, field) do
    kind = to_string(kind)
    {repo_path, repo_runs} = repo || {nil, %{}}

    Enum.find_value(
      [{repo_path, repo_runs, kind}, {repo_path, repo_runs, @default}, {"runs", runs, kind}, {"runs", runs, @default}],
      fn {path, block, entry} -> if get_in(block, [entry, field]), do: "#{path}.#{entry}.#{field}" end
    )
  end

  @doc """
  Every run kind's resolution error, for the operator blocks and each repository's block
  (`{config key, runs}`); empty when every run kind resolves everywhere.
  """
  @spec errors(t(), [repo()], harnesses()) :: [String.t()]
  def errors(runs, repos, harnesses) do
    for repo <- [nil | repos], kind <- RunKind.names(), error <- resolution_errors(repo, runs, harnesses, kind), uniq: true, do: error
  end

  defp resolution_errors(repo, runs, harnesses, kind) do
    case candidates(repo, runs, harnesses, kind) do
      {:ok, _runs} -> []
      {:error, errors} -> errors
    end
  end

  defp layers(repo, runs, kind) do
    repo_runs = if repo, do: elem(repo, 1), else: %{}
    [Map.get(repo_runs, kind, %{}), Map.get(repo_runs, @default, %{}), Map.get(runs, kind, %{}), Map.get(runs, @default, %{})]
  end

  defp entry_path(nil, kind), do: "runs.#{kind}"
  defp entry_path({path, _runs}, kind), do: "#{path}.#{kind}"

  defp field(layers, name), do: Enum.find_value(layers, & &1[name])

  defp required(layers, name, entry) do
    case field(layers, name) do
      nil -> {:error, [missing(entry, name)]}
      value -> {:ok, value}
    end
  end

  defp missing(entry, name) do
    if String.contains?(entry, ".fallbacks["),
      do: "#{entry} changes the harness or the provider, so it must set `#{name}`",
      else: "#{entry} resolves no #{name}; set `#{name}` there or in runs.#{@default}"
  end

  defp supported(harness, provider, entry) do
    if Harnesses.supports?(harness, provider) do
      :ok
    else
      {:error, ["#{entry} runs the #{harness} harness on #{provider}, which it cannot reach; #{harness} runs on: #{Enum.join(Harnesses.providers(harness), ", ")}"]}
    end
  end

  # A run kind's own `command` serves that kind alone, so it is read from the kind's entries
  # and never from a `default`.
  defp own_command(repo, runs, kind) do
    repo_runs = if repo, do: elem(repo, 1), else: %{}
    get_in(repo_runs, [kind, "command"]) || get_in(runs, [kind, "command"])
  end

  defp command(own_command, harnesses, harness, entry) do
    harness_command = harnesses |> Map.get(harness, %{}) |> Map.get(:command)

    case own_command || harness_command do
      nil -> {:error, ["#{entry} runs the #{harness} harness, which has no command; set execution.harnesses.#{harness}.command"]}
      command -> {:ok, command}
    end
  end

  defp small_model(layers, harnesses, harness, provider, entry) do
    own = field(layers, "small_model")
    harness_small_model = harnesses |> Map.get(harness, %{}) |> Map.get(:small_model, %{}) |> Map.get(provider)

    cond do
      not Harnesses.small_model?(harness) -> {:ok, nil}
      own || harness_small_model -> {:ok, own || harness_small_model}
      true -> {:error, ["#{entry} runs the #{harness} harness on #{provider} with no small model for its background calls; set execution.harnesses.#{harness}.small_model.#{provider}"]}
    end
  end

  defp parse_entry(name, entry, path) do
    cond do
      name != @default and name not in RunKind.names() ->
        {:error, ["#{path} is not a run kind; expected #{@default} or one of: #{Enum.join(RunKind.names(), ", ")}"]}

      not is_map(entry) ->
        {:error, ["#{path} must be a map with any of: #{Enum.join(@entry_keys, ", ")}"]}

      true ->
        entry |> Map.new(fn {key, value} -> {to_string(key), value} end) |> parse_entry_fields(name, path)
    end
  end

  defp parse_entry_fields(entry, name, path) do
    allowed = @entry_keys ++ ["fallbacks"]
    unknown = for key <- Map.keys(entry) -- allowed, do: "#{path} has unknown key `#{key}`; expected any of: #{Enum.join(allowed, ", ")}"
    {fallbacks, fallback_errors} = parse_fallbacks(Map.get(entry, "fallbacks"), "#{path}.fallbacks")

    {fields, errors} =
      entry
      |> Map.take(@entry_keys)
      |> Enum.sort()
      |> Enum.reduce({%{}, unknown}, fn {key, value}, {fields, errors} ->
        case check(key, value, name) do
          {:ok, value} -> {Map.put(fields, key, value), errors}
          {:error, message} -> {fields, errors ++ ["#{path}.#{key} #{message}"]}
        end
      end)

    fields = if fallbacks == [], do: fields, else: Map.put(fields, "fallbacks", fallbacks)
    if errors ++ fallback_errors == [], do: {:ok, fields}, else: {:error, errors ++ fallback_errors}
  end

  defp parse_fallbacks(nil, _path), do: {[], []}

  defp parse_fallbacks(fallbacks, path) when is_list(fallbacks) do
    fallbacks
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {fallback, index}, {found, errors} ->
      case parse_fallback(fallback, "#{path}[#{index}]") do
        {:ok, fallback} -> {found ++ [fallback], errors}
        {:error, fallback_errors} -> {found, errors ++ fallback_errors}
      end
    end)
  end

  defp parse_fallbacks(_fallbacks, path), do: {[], ["#{path} must be a list of alternatives"]}

  defp parse_fallback(%{} = fallback, path) do
    fallback = Map.new(fallback, fn {key, value} -> {to_string(key), value} end)
    unknown = for key <- Map.keys(fallback) -- @fallback_keys, do: "#{path} has unknown key `#{key}`; expected any of: #{Enum.join(@fallback_keys, ", ")}"

    {fields, errors} =
      fallback
      |> Map.take(@fallback_keys)
      |> Enum.sort()
      |> Enum.reduce({%{}, unknown}, fn {key, value}, {fields, errors} ->
        case check(key, value, nil) do
          {:ok, value} -> {Map.put(fields, key, value), errors}
          {:error, message} -> {fields, errors ++ ["#{path}.#{key} #{message}"]}
        end
      end)

    if errors == [], do: {:ok, fields}, else: {:error, errors}
  end

  defp parse_fallback(_fallback, path), do: {:error, ["#{path} must be a map with any of: #{Enum.join(@fallback_keys, ", ")}"]}

  defp parse_harness(id, harness, path) do
    cond do
      id not in Harnesses.ids() ->
        {:error, ["#{path} is not a harness; expected one of: #{Enum.join(Harnesses.ids(), ", ")}"]}

      not is_map(harness) ->
        {:error, ["#{path} must be a map with any of: #{Enum.join(@harness_keys, ", ")}"]}

      true ->
        harness |> Map.new(fn {key, value} -> {to_string(key), value} end) |> parse_harness_fields(id, path)
    end
  end

  defp parse_harness_fields(harness, id, path) do
    unknown = for key <- Map.keys(harness) -- @harness_keys, do: "#{path} has unknown key `#{key}`; expected any of: #{Enum.join(@harness_keys, ", ")}"

    command_errors =
      case Map.fetch(harness, "command") do
        :error -> []
        {:ok, command} -> command |> check_command() |> error_at("#{path}.command")
      end

    {small_models, small_model_errors} = parse_small_models(Map.get(harness, "small_model"), id, "#{path}.small_model")

    case unknown ++ command_errors ++ small_model_errors do
      [] -> {:ok, %{command: trimmed(Map.get(harness, "command")), small_model: small_models}}
      errors -> {:error, errors}
    end
  end

  defp parse_small_models(nil, _id, _path), do: {%{}, []}

  defp parse_small_models(%{} = raw, id, path) do
    raw
    |> Enum.sort_by(fn {provider, _model} -> to_string(provider) end)
    |> Enum.reduce({%{}, []}, fn {provider, model}, {models, errors} ->
      provider = to_string(provider)

      cond do
        not Harnesses.supports?(id, provider) ->
          {models, errors ++ ["#{path}.#{provider} is not a provider the #{id} harness reaches; expected one of: #{Enum.join(Harnesses.providers(id), ", ")}"]}

        match?({:error, _message}, check_text(model)) ->
          {models, errors ++ error_at(check_text(model), "#{path}.#{provider}")}

        true ->
          {Map.put(models, provider, String.trim(model)), errors}
      end
    end)
  end

  defp parse_small_models(_raw, _id, path), do: {%{}, ["#{path} must be a map of provider to model"]}

  defp error_at({:ok, _value}, _path), do: []
  defp error_at({:error, message}, path), do: ["#{path} #{message}"]

  defp check("harness", value, _name), do: check_inclusion(value, Harnesses.ids())
  defp check("provider", value, _name), do: check_inclusion(value, Harnesses.all_providers())
  defp check("effort", value, _name), do: check_inclusion(value, @efforts)
  defp check("model", value, _name), do: check_text(value)
  defp check("small_model", value, _name), do: check_text(value)
  defp check("command", _value, @default), do: {:error, "is a run kind's own; a harness's command for every run is execution.harnesses.<harness>.command"}
  defp check("command", value, _name), do: check_command(value)

  defp check_inclusion(value, allowed) do
    if value in allowed, do: {:ok, value}, else: {:error, "must be one of: #{Enum.join(allowed, ", ")}"}
  end

  defp check_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "must not be blank"}
      text -> {:ok, text}
    end
  end

  defp check_text(_value), do: {:error, "must be a string"}

  defp check_command(value) do
    with {:ok, command} <- check_text(value) do
      case Enum.filter(@entry_flags, &Regex.match?(~r/(^|\s)#{&1}(=|\s|$)/, command)) do
        [] -> {:ok, command}
        flags -> {:error, "must not pass #{Enum.join(flags, " or ")}; the run's entry sets the model and effort"}
      end
    end
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: nil
end
