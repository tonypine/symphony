defmodule SymphonyElixir.MachineLabels do
  @moduledoc """
  The labels the machine owns and the guard that keeps them machine-only.

  The machine-owned labels are the pause projector's (`SymphonyElixir.Pauses.Projector.labels/0`:
  `Blocked`, `Needs Decision`) and the interim CI state labels (`CI green` / `CI red` /
  `CI running`); `SymphonyElixir.StateProvisioning` creates them. The design keeps them a
  projection of the store, written and cleared by the machinery alone — agents and people request,
  they never write (`docs/design/state-machine.md` §Attributes).

  `SymphonyElixir.Tracker.add_issue_label/2` and `remove_issue_label/2` refuse these names, so
  no generic caller can touch them; only `Tracker.set_machine_label/2` and
  `Tracker.clear_machine_label/2` write them, and the pause projector alone writes its two.
  """

  alias SymphonyElixir.Pauses.Projector

  @ci_labels ["CI green", "CI red", "CI running"]

  @doc "The machine-owned CI state labels, in the order a projection clears them."
  @spec ci_labels() :: [String.t()]
  def ci_labels, do: @ci_labels

  @doc "Whether the machine owns the label named `name` (matched ignoring case and surrounding space)."
  @spec owned?(String.t() | nil) :: boolean()
  def owned?(name), do: normalize(name) in normalized()

  defp normalized, do: Enum.map(Projector.labels() ++ @ci_labels, &normalize/1)

  defp normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize(_name), do: ""
end
