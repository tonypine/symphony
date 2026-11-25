defmodule SymphonyElixir.OpenRouter do
  @moduledoc """
  Where Symphony reaches OpenRouter: `https://openrouter.ai/api`, the base of both the models
  API (`/v1/models`) and the Anthropic-compatible endpoint `claude` runs talk to.

  QA tests OpenRouter flows against `SymphonyElixir.OpenRouter.Stub` instead of the paid API.
  `SYMPHONY_QA_OPENROUTER_URL` points Symphony at the stub, and only in QA mode: when
  `SYMPHONY_BAR_QA_ROOT` is set (the macOS app's QA mode passes it on to the Symphony it runs)
  and the URL is `http` or `https` on a loopback host. Anywhere else the variable is ignored, so
  a normal run always sends its key to openrouter.ai.
  """

  @base_url "https://openrouter.ai/api"
  @qa_url_env "SYMPHONY_QA_OPENROUTER_URL"
  @qa_root_env "SYMPHONY_BAR_QA_ROOT"
  @loopback_hosts ["127.0.0.1", "localhost", "::1"]

  @doc "The variable that points a QA run at the stub."
  @spec qa_url_env() :: String.t()
  def qa_url_env, do: @qa_url_env

  @doc """
  The OpenRouter API base, without a trailing slash: the stub's URL in QA mode, else
  `https://openrouter.ai/api`.
  """
  @spec base_url(%{optional(String.t()) => String.t()}) :: String.t()
  def base_url(env \\ System.get_env()), do: qa_base_url(env) || @base_url

  @doc """
  The QA stub's API base, without a trailing slash, in QA mode (see the module doc); nil anywhere
  else. Other providers the stub stands in for (OpenCode Go) build their QA URLs on it.
  """
  @spec qa_base_url(%{optional(String.t()) => String.t()}) :: String.t() | nil
  def qa_base_url(env) do
    with root when is_binary(root) <- Map.get(env, @qa_root_env),
         false <- String.trim(root) == "",
         url when is_binary(url) <- Map.get(env, @qa_url_env),
         {:ok, url} <- loopback_url(url) do
      url
    else
      _not_qa -> nil
    end
  end

  defp loopback_url(url) do
    url = url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and host in @loopback_hosts ->
        {:ok, url}

      _other ->
        :error
    end
  end
end
