defmodule SymphonyElixir.QaModeContract do
  @moduledoc """
  Renders "QA mode, what Symphony's driver gives the app": the short section an app repository's
  implementation, rework and QA runs get when its workflow enables the `macos_app` or `android_app`
  playbook, so a QA-mode change is written against the driver's real paths (TP-1346).

  The names come from the drivers themselves (`SymphonyElixir.QaDriver.app_contract/0`,
  `SymphonyElixir.QaAndroid.Driver.downloads_dir/0`, `SymphonyElixir.Verification.env_var/0`) and
  the playbook's own `dev_server_port` and `launch_env`, so the text cannot drift from the code.
  """

  alias SymphonyElixir.PlaybookSettings
  alias SymphonyElixir.QaAgent.PromptTerms
  alias SymphonyElixir.QaAndroid.Driver, as: AndroidDriver
  alias SymphonyElixir.{QaDriver, Verification}

  @heading "QA mode, what Symphony's driver gives the app:"
  # The markers the macOS lines keep, each filled from the driver's contract field it names.
  @contract_fields %{
    "root_env" => :qa_root_env,
    "api_requests_log" => :api_requests_log,
    "api_reads_log" => :api_reads_log,
    "elements_folder" => :elements_folder,
    "cursor_folder" => :cursor_folder,
    "api_fixtures_env" => :api_fixtures_env,
    "appearance_env" => :appearance_env
  }
  @contract_markers ["appearances" | Map.keys(@contract_fields)]

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

  # The macOS lines, built from the driver's QA tools (`PromptTerms`) at compile time, so a tool the
  # driver drops fails the build; the contract's names are filled from the driver at run time.
  @macos_lines Enum.map(
                 [
                   "- `{{root_env}}`: the QA root, the launch's run directory on the QA host. The app keeps its settings and secrets there, and every file the driver reads from the app goes there: `qa_api_requests` reads `{{api_requests_log}}` from the QA root. The app logs its reads (GETs) to `{{api_reads_log}}` beside it, and the tool returns both. The app writes its element report (its named elements, their frames and its state) to `{{elements_folder}}/<pid>.json` there, which `qa_elements`, `qa_scroll_to`, `qa_measure_elements` and `qa_wait_check` read. It writes the cursor it set at the pointer and the named element it set it for to `{{cursor_folder}}/<pid>.json` there, which `qa_hover` reads.",
                   "- `{{api_fixtures_env}}`: read-only, set on a launch with `api_fixtures`. It names a copy on the QA host of the fixture directory the ticket committed; the app reads Symphony's API answers from it and never writes there.",
                   "- `{{appearance_env}}`: {{appearances}} when the launch asks for an appearance."
                 ],
                 &PromptTerms.build!("lib/symphony_elixir/qa_mode_contract.ex: the macOS QA mode", &1, PromptTerms.terms(), keep: @contract_markers)
               )

  defp macos_lines(playbook) do
    contract = QaDriver.app_contract()

    fill = fn line ->
      Enum.reduce(
        @contract_fields,
        String.replace(line, "{{appearances}}", Enum.map_join(contract.appearances, " or ", &"`#{&1}`")),
        fn {marker, field}, text -> String.replace(text, "{{#{marker}}}", Map.fetch!(contract, field)) end
      )
    end

    Enum.map(@macos_lines, fill) ++
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
