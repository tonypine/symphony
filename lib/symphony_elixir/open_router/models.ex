defmodule SymphonyElixir.OpenRouter.Models do
  @moduledoc """
  What each OpenRouter model can do, read from `GET https://openrouter.ai/api/v1/models`.

  Symphony agents reach MCP and shell tools through tool use, so a model must list `tools` in
  its `supported_parameters`. `reasoning` tells whether `--effort` means anything to it.

  The catalog is cached for the life of the process, for `@ttl_ms`. A failed request is not
  cached, so the next lookup tries again. Tests swap the HTTP call with the
  `:openrouter_models_request` app env (a `(url, req_options) -> {:ok, response} | {:error,
  reason}` function) or the `:request_fun` option.
  """

  @endpoint "https://openrouter.ai/api/v1/models"
  @ttl_ms :timer.hours(1)
  @timeout_ms 5_000
  @cache_key {__MODULE__, :catalog}

  @type capabilities :: %{tools: boolean(), reasoning: boolean(), context_length: pos_integer() | nil}
  @type catalog :: %{String.t() => capabilities()}

  @doc "The models API endpoint."
  @spec endpoint() :: String.t()
  def endpoint, do: @endpoint

  @doc """
  The capabilities of `model_id`: `{:error, :unknown_model}` when OpenRouter does not list it,
  `{:error, {:unavailable, reason}}` when the catalog cannot be read.
  """
  @spec lookup(String.t(), keyword()) :: {:ok, capabilities()} | {:error, :unknown_model | {:unavailable, term()}}
  def lookup(model_id, opts \\ []) when is_binary(model_id) do
    case catalog(opts) do
      {:ok, %{^model_id => capabilities}} -> {:ok, capabilities}
      {:ok, _catalog} -> {:error, :unknown_model}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  @doc "Every listed model by id, from the cache while it is fresh, else from the API."
  @spec catalog(keyword()) :: {:ok, catalog()} | {:error, term()}
  def catalog(opts \\ []) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    case :persistent_term.get(@cache_key, nil) do
      {fetched_at_ms, catalog} when now_ms - fetched_at_ms < @ttl_ms ->
        {:ok, catalog}

      _missing_or_stale ->
        with {:ok, catalog} <- fetch(opts) do
          :persistent_term.put(@cache_key, {now_ms, catalog})
          {:ok, catalog}
        end
    end
  end

  @doc "Drops the cached catalog."
  @spec clear_cache() :: :ok
  def clear_cache do
    _erased = :persistent_term.erase(@cache_key)
    :ok
  end

  @doc "A short reason for a failed catalog read, for warnings."
  @spec format_reason(term()) :: String.t()
  def format_reason({:http_status, status}), do: "HTTP #{status}"
  def format_reason(:invalid_body), do: "unexpected response body"
  def format_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  def format_reason(reason), do: inspect(reason)

  defp fetch(opts) do
    request_fun = Keyword.get(opts, :request_fun) || Application.get_env(:symphony_elixir, :openrouter_models_request, &Req.get/2)

    case request_fun.(@endpoint, receive_timeout: @timeout_ms, connect_options: [timeout: @timeout_ms], retry: false) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) -> {:ok, parse(models)}
      {:ok, %{status: 200}} -> {:error, :invalid_body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(models) do
    for %{"id" => id} = model <- models, is_binary(id), into: %{} do
      parameters = List.wrap(model["supported_parameters"])

      {id,
       %{
         tools: "tools" in parameters,
         reasoning: "reasoning" in parameters,
         context_length: context_length(model["context_length"])
       }}
    end
  end

  defp context_length(length) when is_integer(length) and length > 0, do: length
  defp context_length(_length), do: nil
end
