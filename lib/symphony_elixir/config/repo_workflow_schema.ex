defmodule SymphonyElixir.Config.RepoWorkflowSchema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema

  # Recompile this schema when an embed's defaults change; see SystemSchema.
  require Schema.Hooks
  require Schema.Verification

  @primary_key false
  @allowed_keys ~w(hooks prompts verification validation)

  embedded_schema do
    field(:configured_paths, :map, virtual: true, default: %{})
    embeds_one(:hooks, Schema.Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:verification, Schema.Verification, on_replace: :update, defaults_to_struct: true)
    field(:prompts, :map, default: %{})
    field(:validation, {:array, :string}, default: [])
  end

  @type t :: %__MODULE__{}

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_repo_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config = normalize_keys(config)
    configured_paths = configured_paths(config)

    with :ok <- reject_removed_keys(config),
         :ok <- reject_unknown_keys(config) do
      config
      |> drop_nil_values()
      |> changeset()
      |> apply_action(:validate)
      |> case do
        {:ok, workflow} -> {:ok, %{workflow | configured_paths: configured_paths}}
        {:error, changeset} -> {:error, {:invalid_repo_workflow_config, format_errors(changeset)}}
      end
    end
  end

  @spec to_config_map(t()) :: map()
  def to_config_map(%__MODULE__{} = workflow) do
    configured_paths = workflow.configured_paths || %{}

    %{}
    |> maybe_put("hooks", configured_map(configured_paths, "hooks", &hooks_to_map(workflow.hooks, &1)))
    |> maybe_put("prompts", workflow.prompts)
    |> maybe_put("verification", configured_map(configured_paths, "verification", &verification_to_map(workflow.verification, &1)))
    |> maybe_put("validation", workflow.validation)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:prompts, :validation], empty_values: [])
    |> cast_embed(:hooks, with: &Schema.Hooks.changeset/2)
    |> cast_embed(:verification, with: &Schema.Verification.changeset/2)
    |> validate_prompts()
    |> validate_string_list(:validation)
  end

  defp validate_prompts(changeset) do
    validate_change(changeset, :prompts, fn :prompts, prompts ->
      cond do
        !is_map(prompts) ->
          [prompts: "must be a map"]

        Enum.any?(Map.keys(prompts), &(&1 not in ["issue", "pr"])) ->
          [prompts: "supports only `issue` and `pr` keys"]

        Enum.any?(prompts, fn {_key, value} -> not is_binary(value) end) ->
          [prompts: "values must be strings"]

        true ->
          []
      end
    end)
  end

  defp reject_unknown_keys(config) do
    unknown_keys = Map.keys(config) -- @allowed_keys

    case unknown_keys do
      [] ->
        :ok

      [key | _rest] ->
        {:error, {:invalid_repo_workflow_config, "WORKFLOW.md contains operator-level key `#{key}`; move operator-owned configuration to symphony.yml"}}
    end
  end

  defp reject_removed_keys(config) do
    if Map.has_key?(config, "self_review") do
      {:error, {:invalid_repo_workflow_config, "`self_review` has been removed; use `pre_push_review` in symphony.yml instead"}}
    else
      :ok
    end
  end

  defp validate_string_list(changeset, field) do
    validate_change(changeset, field, fn ^field, values ->
      invalid? = Enum.any?(values || [], &(not is_binary(&1) or String.trim(&1) == ""))

      if invalid?, do: [{field, "must contain only non-empty strings"}], else: []
    end)
  end

  defp hooks_to_map(nil, _paths), do: nil

  defp hooks_to_map(%Schema.Hooks{} = hooks, paths) do
    %{
      "after_create" => configured_value(paths, "after_create", hooks.after_create),
      "before_run" => configured_value(paths, "before_run", hooks.before_run),
      "after_run" => configured_value(paths, "after_run", hooks.after_run),
      "before_remove" => configured_value(paths, "before_remove", hooks.before_remove),
      "timeout_ms" => configured_value(paths, "timeout_ms", hooks.timeout_ms)
    }
    |> drop_nil_values()
  end

  defp verification_to_map(nil, _paths), do: nil

  defp verification_to_map(%Schema.Verification{} = verification, paths) do
    %{
      "enabled" => configured_value(paths, "enabled", verification.enabled),
      "port_allocation" =>
        configured_map(paths, "port_allocation", fn port_paths ->
          %{
            "range" => configured_value(port_paths, "range", verification.port_allocation.range)
          }
        end),
      "dev_server" =>
        configured_map(paths, "dev_server", fn dev_server_paths ->
          %{
            "start_cmd" => configured_value(dev_server_paths, "start_cmd", verification.dev_server.start_cmd),
            "health_check_url" => configured_value(dev_server_paths, "health_check_url", verification.dev_server.health_check_url),
            "health_timeout_ms" => configured_value(dev_server_paths, "health_timeout_ms", verification.dev_server.health_timeout_ms),
            "stop_signal" => configured_value(dev_server_paths, "stop_signal", verification.dev_server.stop_signal),
            "stop_timeout_ms" => configured_value(dev_server_paths, "stop_timeout_ms", verification.dev_server.stop_timeout_ms)
          }
        end)
    }
    |> drop_nil_values()
  end

  defp configured_map(paths, key, fun) when is_map(paths) and is_function(fun, 1) do
    if Map.has_key?(paths, key) do
      key_paths = Map.get(paths, key)
      fun.(if is_map(key_paths), do: key_paths, else: %{})
    end
  end

  defp configured_value(paths, key, value) when is_map(paths) do
    if Map.has_key?(paths, key), do: value
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp configured_paths(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, paths ->
      Map.put(paths, normalize_key(key), configured_paths(raw_value))
    end)
  end

  defp configured_paths(_value), do: %{}

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        dropped -> Map.put(acc, key, dropped)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix = if is_nil(prefix), do: to_string(key), else: prefix <> "." <> to_string(key)
      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      error when is_binary(error) -> [prefix <> " " <> error]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", inspect(value))
    end)
  end
end
