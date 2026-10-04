defmodule SymphonyElixir.DependencyAudit.MixParser do
  @moduledoc false

  alias SymphonyElixir.DependencyAudit

  @spec parse(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def parse(content, opts \\ []) when is_binary(content) do
    path = Keyword.get(opts, :path, "mix.exs")

    with {:ok, ast} <- Code.string_to_quoted(content),
         {:ok, deps_ast} <- deps_ast(ast) do
      parse_deps(deps_ast, path)
    end
  end

  @doc """
  Parses a `mix.lock` into `%{package => version}`. A Hex package's version is its locked
  release (`"1.4.4"`); any other SCM's is `"<scm>:<ref>"` (`"git:0123abc"`). Atoms in the
  file are read without creating any.
  """
  @spec parse_lock(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def parse_lock(content) when is_binary(content) do
    encode_atom = fn atom, _meta -> {:ok, {:atom, atom}} end

    case Code.string_to_quoted(content, emit_warnings: false, static_atoms_encoder: encode_atom) do
      {:ok, {:%{}, _meta, entries}} -> {:ok, Map.new(for {package, entry} <- entries, do: {lock_name(package), lock_version(entry)})}
      {:ok, _ast} -> {:error, :lock_not_a_map}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_version({:{}, _meta, [{:atom, "hex"}, _name, version | _rest]}) when is_binary(version), do: version
  defp lock_version({:{}, _meta, [{:atom, scm}, _source, ref | _rest]}) when is_binary(ref), do: "#{scm}:#{ref}"
  defp lock_version(_entry), do: "unknown"

  defp lock_name({:atom, name}), do: name
  defp lock_name(name) when is_binary(name), do: name
  defp lock_name(name), do: Macro.to_string(name)

  defp deps_ast(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {def_kind, _meta, [{:deps, _deps_meta, args}, [do: body]]} = node, nil
        when def_kind in [:def, :defp] and args in [nil, []] ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    case found do
      nil -> {:error, :deps_function_not_found}
      deps -> {:ok, deps}
    end
  end

  defp parse_deps(deps_ast, path) when is_list(deps_ast) do
    deps_ast
    |> Enum.map(&parse_dep(&1, path))
    |> collect_results()
  end

  defp parse_deps(_deps_ast, _path), do: {:error, :deps_not_literal_list}

  defp parse_dep({package, requirement}, path) when is_atom(package) and is_binary(requirement) do
    dep(package, path, registry_source("hex.pm", requirement))
  end

  defp parse_dep({package, opts}, path) when is_atom(package) and is_list(opts) do
    if Keyword.keyword?(opts) do
      dep(package, path, source_from_opts(opts, nil))
    else
      {:error, {:unsupported_dependency, package}}
    end
  end

  defp parse_dep({:{}, _meta, [package, requirement, opts]}, path)
       when is_atom(package) and is_binary(requirement) and is_list(opts) do
    if Keyword.keyword?(opts) do
      dep(package, path, source_from_opts(opts, requirement))
    else
      {:error, {:unsupported_dependency, package}}
    end
  end

  defp parse_dep(_dep_ast, _path), do: {:error, :unsupported_dependency_syntax}

  defp source_from_opts(opts, requirement) do
    cond do
      git = keyword_string(opts, :git) ->
        git_source(git, requirement)

      path = keyword_string(opts, :path) ->
        %{type: :path, path: path, requirement: requirement}

      repo = keyword_string(opts, :repo) ->
        registry_source(repo, requirement)

      repo = Keyword.get(opts, :repo) ->
        registry_source(to_string(repo), requirement)

      true ->
        registry_source("hex.pm", requirement)
    end
  end

  defp registry_source(registry, requirement) do
    %{type: :registry, registry: normalize_registry(registry), requirement: requirement}
  end

  defp normalize_registry(registry) when registry in ["hexpm", ":hexpm"], do: "hex.pm"
  defp normalize_registry(registry), do: registry

  defp git_source(url, requirement) do
    case DependencyAudit.normalize_git_url(url) do
      nil -> %{type: :unknown, raw: url, requirement: requirement}
      parts -> parts |> Map.take([:host, :owner, :repo, :normalized]) |> Map.merge(%{type: :git, url: url, requirement: requirement})
    end
  end

  defp dep(package, path, source) do
    {:ok, %{package: Atom.to_string(package), path: path, source: source}}
  end

  defp keyword_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, dep}, {:ok, acc} -> {:cont, {:ok, [dep | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, deps} -> {:ok, Enum.reverse(deps)}
      error -> error
    end
  end
end
