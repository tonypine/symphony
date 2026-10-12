defmodule SymphonyElixir.Sessions do
  @moduledoc """
  Every live session, of any kind, in one list: agent runs (their kind from the run profile),
  Auto Review QA passes (`qa_pass`) and acceptance gate passes (`acceptance_gate`). Landing runs
  are agent runs, so `finishing` adds none. `/api/v1/state`, the web dashboard, the terminal
  dashboard and the macOS app all read what runs from this list.
  """

  @type session :: %{
          kind: String.t(),
          issue_id: String.t(),
          issue_identifier: String.t() | nil,
          repo_key: String.t() | nil,
          started_at: DateTime.t() | nil
        }

  @pass_kinds ["qa_pass", "acceptance_gate"]

  @doc "The sessions of the agent runs, then the QA passes, then the acceptance gate passes."
  @spec list([map()], [map()], [map()]) :: [session()]
  def list(running, qa_running, gate_running) do
    agent_sessions =
      Enum.map(running, fn entry ->
        session(agent_kind(entry), entry.issue_id, entry.identifier, Map.get(entry, :repo_key), Map.get(entry, :started_at))
      end)

    pass_sessions =
      for {kind, passes} <- [{"qa_pass", qa_running}, {"acceptance_gate", gate_running}], pass <- passes do
        session(kind, pass.issue_id, Map.get(pass, :identifier), Map.get(pass, :repo_key), Map.get(pass, :started_at))
      end

    agent_sessions ++ pass_sessions
  end

  @doc "True for a session that is not an agent run: a QA pass or an acceptance gate pass."
  @spec pass?(session()) :: boolean()
  def pass?(%{kind: kind}), do: kind in @pass_kinds

  @doc ~S(The kind in words, for example "QA pass", "acceptance gate pass" or "code review run".)
  @spec label(String.t()) :: String.t()
  def label("qa_pass"), do: "QA pass"
  def label("acceptance_gate"), do: "acceptance gate pass"
  def label("qa"), do: "QA run"
  def label(kind), do: String.replace(kind, "_", " ") <> " run"

  defp agent_kind(entry) do
    profile = Map.get(entry, :run_profile) || %{}
    to_string(Map.get(profile, :kind) || Map.get(entry, :run_kind) || :agent)
  end

  defp session(kind, issue_id, identifier, repo_key, started_at) do
    %{kind: kind, issue_id: issue_id, issue_identifier: identifier, repo_key: repo_key, started_at: started_at}
  end
end
