defmodule SymphonyElixir.SupervisorCheck do
  @moduledoc """
  The `## Supervisor check` block an agent leaves when all that is left of a ticket is a check
  an agent can't run: launching the app, a host crash check, a check on a device.

  The check never goes to a person: the agent moves the ticket to `In Review`, the supervisor's
  queue, and the supervisor runs the check per its policy. The block says what to verify and how:

      ## Supervisor check

      **Verify:** the Companies toolbar stays off the details inspector on `main` (shipped by TP-668).
      **How:** run the host crash check on the macOS app at `main`, open Companies, open a company.
      **Pass when:** no crash report, and the toolbar sits in the page header.

  It may stand alone in a comment or sit inside the review brief. A ticket with no pull request
  (its work already on the default branch) whose run left one may move to `In Review` with Auto
  Review on: there is no PR for Auto Review to test.
  """

  @heading "## Supervisor check"

  @doc "The heading that starts the block."
  @spec heading() :: String.t()
  def heading, do: @heading

  @doc "Whether a comment body holds a supervisor check: a line that is the heading."
  @spec in_body?(String.t() | nil) :: boolean()
  def in_body?(body) when is_binary(body), do: body |> String.split("\n") |> Enum.any?(&(String.trim(&1) == @heading))
  def in_body?(_body), do: false
end
