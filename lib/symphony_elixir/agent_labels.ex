defmodule SymphonyElixir.AgentLabels do
  @moduledoc """
  Human-facing labels derived from the configured agent kind.
  """

  @known_kinds ["codex", "claude"]
  @workpad_heading "## Symphony Workpad"

  @type agent_context :: %{
          required(:kind) => String.t() | nil,
          required(:display_name) => String.t(),
          required(:update_label) => String.t(),
          required(:workpad_heading) => String.t()
        }

  @spec display_name(String.t() | atom() | nil) :: String.t()
  def display_name(kind) do
    case normalize_kind(kind) do
      "codex" -> "Codex"
      "claude" -> "Claude"
      "opencode" -> "OpenCode"
      _ -> "Agent"
    end
  end

  @spec update_label(String.t() | atom() | nil) :: String.t()
  def update_label(kind), do: "#{display_name(kind)} update"

  @doc """
  Canonical workpad heading. Agent-agnostic: the workpad belongs to Symphony, not
  the model backend, so the heading is the same regardless of agent kind.
  """
  @spec workpad_heading(String.t() | atom() | nil) :: String.t()
  def workpad_heading(_kind), do: @workpad_heading

  @doc """
  Workpad headings to search for when reusing an existing comment: the canonical
  `## Symphony Workpad` plus the legacy per-agent headings, so in-flight issues
  created before the rename are still found and rewritten.
  """
  @spec known_workpad_markers() :: [String.t()]
  def known_workpad_markers, do: [@workpad_heading | Enum.map(@known_kinds, &legacy_workpad_heading/1)]

  defp legacy_workpad_heading(kind), do: "## #{display_name(kind)} Workpad"

  @spec prompt_context(String.t() | atom() | nil) :: agent_context()
  def prompt_context(kind) do
    normalized_kind = normalize_kind(kind)

    %{
      kind: normalized_kind,
      display_name: display_name(normalized_kind),
      update_label: update_label(normalized_kind),
      workpad_heading: workpad_heading(normalized_kind)
    }
  end

  @spec normalize_kind(String.t() | atom() | nil) :: String.t() | nil
  def normalize_kind(nil), do: nil

  def normalize_kind(kind) when is_atom(kind), do: kind |> Atom.to_string() |> normalize_kind()

  def normalize_kind(kind) when is_binary(kind) do
    case kind |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_kind(_kind), do: nil
end
