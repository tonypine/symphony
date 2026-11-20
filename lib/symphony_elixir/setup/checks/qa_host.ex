defmodule SymphonyElixir.Setup.Checks.QaHost do
  @moduledoc """
  Where `macos_app` QA runs. It runs only in a QA VM (`auto_review.worker_host`), never on the
  Symphony Mac, so Setup reports:

    * a repo whose playbooks include `macos_app` while no `worker_host` is set: its QA passes build
      and launch nothing, and their app steps come back `blocked`;
    * a `worker_host` that is this Mac under another name (`localhost`, its `.local` name, a LAN
      address): the hardware compare of `SymphonyElixir.QaDriver.Machine` reads the same
      `IOPlatformUUID` over SSH as here, and every pass refuses it;
    * a QA VM whose screen, in points, is under the wide pass size its repos' `macos_app`
      playbooks need (`wide_pass_width`×`wide_pass_height`, 2560×1440 by default): every wide pass
      there is limited and its `pass` comes back `blocked`. The size is the main display's, as
      `system_profiler SPDisplaysDataType` reports what it looks like, so a Retina mode of a
      2560×1440 display reads 1280×720. The problem names the `tart set` command that fixes it.

  The `worker_host` is only read when a repo runs `macos_app`. A QA host it can't reach leaves the
  check under `not_checked`. Every fix opens the QA VM docs: the setting has no control in the app.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.{Config, PlaybookSettings}
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
          playbook = Enum.find(Selection.playbooks(settings.auto_review), &(Map.get(&1, :kind) == "macos_app")),
          playbook != nil,
          do: {repo.name, settings.auto_review.worker_host, Map.get(playbook, :wide_pass_size) || PlaybookSettings.default_wide_pass_size()}

    {missing, hosted} = Enum.split_with(uses, fn {_repo, worker_host, _size} -> is_nil(worker_host) end)

    with {:ok, same_machine} <- same_machine_problems(Enum.map(hosted, fn {repo, host, _size} -> {repo, host} end)),
         {:ok, screens} <- screen_problems(hosted, same_machine) do
      missing_problems(Enum.map(missing, &elem(&1, 0))) ++ same_machine ++ screens
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

  # A QA host that is this Mac already has its problem: its screen is not the VM's.
  defp screen_problems(hosted, same_machine) do
    refused = MapSet.new(same_machine, & &1.id)

    hosted
    |> Enum.reject(fn {_repo, worker_host, _size} -> MapSet.member?(refused, "#{id()}:same_machine:#{worker_host}") end)
    |> Enum.group_by(&elem(&1, 1), &{elem(&1, 0), elem(&1, 2)})
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {worker_host, uses}, {:ok, problems} ->
      case Machine.screen_points(qa_cmd(worker_host)) do
        {:ok, screen} -> {:cont, {:ok, problems ++ small_screen_problem(worker_host, screen, uses)}}
        {:error, reason} -> {:halt, {:error, "the QA host #{worker_host}: the screen size could not be read: #{reason}"}}
      end
    end)
  end

  defp small_screen_problem(worker_host, {sw, sh} = screen, uses) do
    {nw, nh} = needed = uses |> Enum.map(&elem(&1, 1)) |> Enum.reduce(fn {w, h}, {mw, mh} -> {max(w, mw), max(h, mh)} end)
    repos = uses |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    if sw < nw or sh < nh do
      command = "tart set <the QA VM> --display #{nw}x#{nh}pt"

      [
        Problem.new(
          id: "#{id()}:small_screen:#{worker_host}",
          severity: :error,
          category: :runtime,
          title: "The QA VM's screen is too small for the wide pass",
          consequence:
            "The QA host #{worker_host} has a #{size(screen)} screen, under the #{size(needed)} the wide pass of " <>
              "#{Enum.join(repos, ", ")} fills, so every wide pass there is limited and a QA pass that passes comes back blocked. " <>
              "On the Mac that runs the VM, run #{command} with the VM stopped, then start it again.",
          repos: repos,
          details: [Host: worker_host, Screen: size(screen), Needs: size(needed), Fix: command],
          fix: Problem.open(:symphony_yml, @docs_url)
        )
      ]
    else
      []
    end
  end

  defp size({w, h}), do: "#{w}×#{h} pt"

  # Tests set `:setup_qa_machine` to fake both sides' `ioreg` and the QA host's `system_profiler`.
  defp same_machine?(worker_host) do
    opts = Application.get_env(:symphony_elixir, :setup_qa_machine, [])
    Machine.same_machine?(qa_cmd(worker_host), Keyword.get(opts, :local_uuid, &Machine.local_uuid/0))
  end

  defp qa_cmd(worker_host) do
    qa_cmd = :symphony_elixir |> Application.get_env(:setup_qa_machine, []) |> Keyword.get(:qa_cmd, &Remote.cmd/4)
    &qa_cmd.(worker_host, &1, &2, &3)
  end
end
