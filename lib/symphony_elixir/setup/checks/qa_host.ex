defmodule SymphonyElixir.Setup.Checks.QaHost do
  @moduledoc """
  Where `macos_app` QA runs. It runs only in a QA VM (`auto_review.worker_host`), never on the
  Symphony Mac, so Setup reports:

    * a repo whose playbooks include `macos_app` while no `worker_host` is set: its QA passes build
      and launch nothing, and their app steps come back `blocked`;
    * a `worker_host` that is this Mac under another name (`localhost`, its `.local` name, a LAN
      address): the hardware compare of `SymphonyElixir.QaDriver.Machine` reads the same
      `IOPlatformUUID` over SSH as here, and every pass refuses it.

  The `worker_host` is only read when a repo runs `macos_app`. A QA host it can't reach leaves the
  check under `not_checked`. Both fixes open the QA VM docs: the setting has no control in the app.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Config
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.QaDriver.{Machine, Remote}
  alias SymphonyElixir.Setup.Problem

  @docs_url "https://github.com/tonypine/symphony/blob/main/docs/configuration.md#running-qa-in-a-qa-vm"

  @impl true
  def id, do: "qa_host"

  @impl true
  def title, do: "Where macOS app QA runs"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system}) do
    uses =
      for repo <- system.repos,
          {:ok, settings} <- [Config.settings_for_repo(repo.name)],
          Enum.any?(Selection.playbooks(settings.auto_review), &(Map.get(&1, :kind) == "macos_app")),
          do: {repo.name, settings.auto_review.worker_host}

    {missing, hosted} = Enum.split_with(uses, fn {_repo, worker_host} -> is_nil(worker_host) end)

    with {:ok, same_machine} <- same_machine_problems(hosted) do
      missing_problems(Enum.map(missing, &elem(&1, 0))) ++ same_machine
    end
  end

  defp missing_problems([]), do: []

  defp missing_problems(repos) do
    [
      Problem.new(
        id: "#{id()}:missing",
        severity: :error,
        category: :runtime,
        title: "macOS app QA has no QA VM",
        consequence:
          "QA of #{Enum.join(repos, ", ")} builds and launches no macOS app: it runs only in a QA VM, and no auto_review.worker_host names one, " <>
            "so every pass marks the app steps blocked.",
        repos: repos,
        details: [Key: "auto_review.worker_host", Playbook: "macos_app"],
        fix: Problem.open(:symphony_yml, @docs_url)
      )
    ]
  end

  defp same_machine_problems(hosted) do
    hosted
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {worker_host, repos}, {:ok, problems} ->
      case same_machine?(worker_host) do
        {:ok, true} -> {:cont, {:ok, problems ++ [same_machine_problem(worker_host, repos)]}}
        {:ok, false} -> {:cont, {:ok, problems}}
        {:error, reason} -> {:halt, {:error, "the QA host #{worker_host}: #{reason}"}}
      end
    end)
  end

  defp same_machine_problem(worker_host, repos) do
    Problem.new(
      id: "#{id()}:same_machine:#{worker_host}",
      severity: :error,
      category: :runtime,
      title: "The QA host #{worker_host} is this Mac",
      consequence:
        "QA of #{Enum.join(repos, ", ")} refuses it and builds and launches no macOS app: QA runs only in a VM, never on the Symphony Mac, " <>
          "where PR code would run beside your credentials.",
      repos: repos,
      details: [Key: "auto_review.worker_host", Value: worker_host],
      fix: Problem.open(:symphony_yml, @docs_url)
    )
  end

  # Tests set `:setup_qa_machine` to fake both sides' `ioreg`.
  defp same_machine?(worker_host) do
    opts = Application.get_env(:symphony_elixir, :setup_qa_machine, [])
    qa_cmd = Keyword.get(opts, :qa_cmd, &Remote.cmd/4)
    Machine.same_machine?(&qa_cmd.(worker_host, &1, &2, &3), Keyword.get(opts, :local_uuid, &Machine.local_uuid/0))
  end
end
