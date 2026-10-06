defmodule SymphonyElixir.AutoReview.HoldNote do
  @moduledoc """
  The note on an issue whose QA pass is held until the provider's usage limit resets:
  `QA is waiting for the usage limit to reset at 14:05.` Without it nothing on the issue says
  why Auto Review is idle.

  Symphony posts it when it holds the pass, rewrites the same comment when a later pass is
  held again, and deletes it once a pass runs (see `SymphonyElixir.AutoReview.run_qa/2`).
  Only Linear gets the note: other trackers can't edit or delete a comment.
  """

  alias SymphonyElixir.{Config, UsageLimit}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Report

  # Both wordings start with it, so a held pass finds the note whichever cause held it before.
  @prefix "QA is waiting for the "

  @doc """
  The note for a hold on `usage_limit` until `resume_at`, in local time.
  `opts[:now]` and `opts[:to_local]` are for tests (see `SymphonyElixir.UsageLimit.local_time/3`).
  """
  @spec render(map(), DateTime.t(), keyword()) :: String.t()
  def render(usage_limit, %DateTime{} = resume_at, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    at = UsageLimit.local_time(resume_at, now, Keyword.take(opts, [:to_local]))

    waiting =
      if UsageLimit.api_unreachable?(usage_limit),
        do: @prefix <> "model API to come back; it tries again at #{at}.",
        else: @prefix <> "usage limit to reset at #{at}."

    waiting <> " Auto Review runs the pass again then, and Symphony removes this note when it does.\n"
  end

  @doc """
  Posts the note, or rewrites the one already on the issue. Returns `:skipped` when the
  tracker isn't Linear.
  """
  @spec post(Issue.t(), map(), DateTime.t(), keyword()) :: :ok | :skipped | {:error, term()}
  def post(%Issue{} = issue, usage_limit, %DateTime{} = resume_at, opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    if settings.tracker.kind == "linear",
      do: Report.publish(issue, render(usage_limit, resume_at, opts), linear_opts(opts)),
      else: :skipped
  end

  @doc "Deletes the note. An issue without one is fine."
  @spec withdraw(Issue.t(), keyword()) :: :ok | {:error, term()}
  def withdraw(%Issue{} = issue, opts \\ []), do: Report.withdraw(issue, linear_opts(opts))

  defp linear_opts(opts), do: [heading: @prefix] ++ Keyword.take(opts, [:linear_client, :settings])
end
