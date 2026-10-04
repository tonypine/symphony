defmodule SymphonyElixir.BuildInfo do
  @moduledoc """
  The build of Symphony that is running: its version, the commit it was built from and the
  repository that commit lives in.

  The release workflow sets `SYMPHONY_BUILD_SHA`, `SYMPHONY_BUILD_REPO` and
  `SYMPHONY_BUILD_NUMBER` when it builds the binary, and `mix.exs` records them in the
  application environment under `:build`. A build from a checkout has no sha or repository.
  """

  @type t :: %{version: String.t(), sha: String.t() | nil, repo: String.t() | nil}

  @doc """
  The running build. `version` matches the menu bar app's, for example `0.0.1.168`; `sha` is the
  full commit sha, nil when it is missing or not a hex sha.
  """
  @spec current() :: t()
  def current do
    build = Application.get_env(:symphony_elixir, :build, [])
    vsn = :symphony_elixir |> Application.spec(:vsn) |> to_string()

    %{
      version: version(vsn, present(build[:number])),
      sha: sha(build[:sha]),
      repo: present(build[:repo])
    }
  end

  @doc "The first seven characters of a commit sha, as Git abbreviates it."
  @spec short_sha(String.t()) :: String.t()
  def short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)

  defp version(vsn, nil), do: vsn
  defp version(vsn, number), do: "#{vsn}.#{number}"

  defp sha(value) do
    case present(value) do
      sha when is_binary(sha) -> if sha =~ ~r/\A[0-9a-f]{7,40}\z/i, do: String.downcase(sha)
      nil -> nil
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
