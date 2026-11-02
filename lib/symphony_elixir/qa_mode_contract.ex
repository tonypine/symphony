defmodule SymphonyElixir.QaModeContract do
  @moduledoc """
  Renders "QA mode, what Symphony's driver gives the app": the short section an app repository's
  implementation, rework and QA runs get when its workflow enables the `macos_app` or `android_app`
  playbook, so a QA-mode change is written against the driver's real paths (TP-1346).

  The names come from the drivers themselves (`SymphonyElixir.QaDriver.app_contract/0`,
  `SymphonyElixir.QaAndroid.Driver.downloads_dir/0`, `SymphonyElixir.Verification.env_var/0`) and
  the playbook's own `dev_server_port` and `launch_env`, so the text cannot drift from the code.
  """

  alias SymphonyElixir.QaAgent.PlaybookSettings
  alias SymphonyElixir.QaAndroid.Driver, as: AndroidDriver
  alias SymphonyElixir.{QaDriver, Verification}

  @heading "QA mode, what Symphony's driver gives the app:"

  @doc """
  The section for the enabled `playbooks` (`SymphonyElixir.QaAgent.Selection.playbooks/2`), or
  `nil` when none of them is `macos_app` or `android_app`.
  """
  @spec section([map()]) :: String.t() | nil
  def section(playbooks) when is_list(playbooks) do
    lines =
      Enum.flat_map(playbooks, fn
        %{kind: "macos_app"} = playbook -> macos_lines(playbook)
        %{kind: "android_app"} -> android_lines()
        _other -> []
      end)

    if lines == [], do: nil, else: Enum.join([@heading, "" | lines], "\n")
  end

  defp macos_lines(playbook) do
    contract = QaDriver.app_contract()

    [
      "- `#{contract.qa_root_env}`: the QA root, the launch's run directory on the QA host. The app keeps its settings and secrets there, and every file the driver reads from the app goes there: `qa_api_requests` reads `#{contract.api_requests_log}` from the QA root.",
      "- `#{contract.api_fixtures_env}`: read-only, set on a launch with `api_fixtures`. It names a copy on the QA host of the fixture directory the ticket committed; the app reads Symphony's API answers from it and never writes there.",
      "- `#{contract.appearance_env}`: #{Enum.map_join(contract.appearances, " or ", &"`#{&1}`")} when the launch asks for an appearance."
    ] ++
      dev_server_lines(playbook) ++
      ["- Write what QA must read into the QA root (`$#{contract.qa_root_env}`); read what the ticket committed from the fixtures copy (`$#{contract.api_fixtures_env}`)."]
  end

  defp dev_server_lines(%{dev_server: true} = playbook) do
    port = Map.get(playbook, :dev_server_port) || PlaybookSettings.default_port()

    env_line =
      case PlaybookSettings.launch_env(playbook) do
        {:ok, [_ | _] = env} -> " The app gets " <> Enum.map_join(env, ", ", fn {name, value} -> "`#{name}=#{value}`" end) <> "."
        _none -> " The playbook's `launch_env` names the variables that carry its URL to the app."
      end

    ["- The dev server runs on the QA host on port #{port} (`#{Verification.env_var()}`)." <> env_line]
  end

  defp dev_server_lines(_playbook), do: []

  defp android_lines do
    [
      "- Android: the driver hands the app no variables. `qa_android_put_file` puts a fixture file in `#{AndroidDriver.downloads_dir()}` on the emulator, the only folder it writes, where the system file picker offers it; a reinstall wipes the app's data, not that folder.",
      "- Android: `qa_android_dark_mode` switches the emulator's night mode, so the app draws dark when it follows the system."
    ]
  end
end
