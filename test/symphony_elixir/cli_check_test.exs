defmodule SymphonyElixir.CLICheckTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias SymphonyElixir.CLI
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Workflow

  @secret "lin_api_check_secret_value"

  setup do
    original_symphony_path = Application.get_env(:symphony_elixir, :symphony_file_path)
    original_cache_watch = Application.get_env(:symphony_elixir, :config_cache_watch)
    root = Path.join(System.tmp_dir!(), "symphony-cli-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "app"))
    File.write!(Path.join([root, "app", "WORKFLOW.md"]), "Repo prompt\n")
    Application.put_env(:symphony_elixir, :config_cache_watch, false)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      restore_app_env(:symphony_file_path, original_symphony_path)
      restore_app_env(:config_cache_watch, original_cache_watch)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "exits 0 and prints the resolved path for a valid config", %{root: root} do
    path = write_symphony!(root, valid_symphony(root))

    {result, output} = check(["--config", path])

    assert result == {:halt, 0}
    assert output == "Config OK: #{path}\n"
    assert Workflow.symphony_file_path() == path
    refute_received :runtime_started
  end

  test "defaults to symphony.yml in the current folder", %{root: root} do
    path = write_symphony!(root, valid_symphony(root))

    {result, output} = File.cd!(root, fn -> check([]) end)

    assert result == {:halt, 0}
    assert output == "Config OK: #{path}\n"
  end

  test "reports invalid YAML with its location", %{root: root} do
    path = write_symphony!(root, "issues: [unclosed\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message == "Config error in #{path}: Failed to parse symphony.yml: Unfinished flow collection (line: 1, column: 18)"
  end

  test "reports an unknown key", %{root: root} do
    path = write_symphony!(root, valid_symphony(root) <> "bogus_top: 1\n")

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "Config error in #{path}: "
    assert message =~ "unknown symphony.yml key `bogus_top`"
  end

  test "reports an invalid value without echoing it", %{root: root} do
    content = String.replace(valid_symphony(root), "provider: memory", "provider: memory\n  poll_interval_ms: #{@secret}")
    path = write_symphony!(root, content)

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "issues.poll_interval_ms is invalid"
    refute message =~ @secret
  end

  test "reports run profile errors naming the key", %{root: root} do
    cases = [
      {"command: codex app-server\n  run_profiles:\n    bogus:\n      effort: low", "agent.run_profiles has unknown run kind `bogus`"},
      {"command: codex app-server\n  effort: extreme", "agent.effort must be one of: low, medium, high, xhigh, max"},
      {"command: claude --effort high\n  effort: low", "agent.command must not pass --effort when agent.model, agent.effort or agent.run_profiles is set"}
    ]

    for {agent_lines, expected} <- cases do
      Cache.clear()
      path = write_symphony!(root, String.replace(valid_symphony(root), "command: codex app-server", agent_lines))

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "Config error in #{path}: "
      assert message =~ expected
    end
  end

  test "reports pre-push reviewer and QA agent profile errors naming the key", %{root: root} do
    cases = [
      {"pre_push_review:\n  effort: extreme\n", "pre_push_review.effort must be one of: low, medium, high, xhigh, max"},
      {"auto_review:\n  effort: extreme\n", "auto_review.effort must be one of: low, medium, high, xhigh, max"},
      {"pre_push_review:\n  command: claude --model x\n  effort: low\n", "pre_push_review.command must not pass --model"},
      {"auto_review:\n  command: claude --effort high\n  model: y\n", "auto_review.command must not pass --effort"}
    ]

    for {section, expected} <- cases do
      Cache.clear()
      path = write_symphony!(root, valid_symphony(root) <> section)

      assert {{:error, message}, ""} = check(["--config", path])
      assert message =~ "Config error in #{path}: "
      assert message =~ expected
    end
  end

  test "reports a broken repo WORKFLOW.md", %{root: root} do
    File.write!(Path.join([root, "app", "WORKFLOW.md"]), "---\nbogus_workflow_key: 1\n---\nPrompt\n")
    path = write_symphony!(root, valid_symphony(root))

    assert {{:error, message}, ""} = check(["--config", path])
    assert message =~ "Config error in #{path}: "
    assert message =~ "repo app"
    assert message =~ "bogus_workflow_key"
  end

  test "reports a missing config file without validating", %{root: root} do
    path = Path.join(root, "missing.yml")

    assert {{:error, message}, ""} = check(["--config", path], check_config: fn -> flunk("validated a missing file") end)
    assert message == "Symphony config file not found: #{path}"
  end

  test "rejects unexpected arguments with check usage" do
    assert {{:error, message}, ""} = check(["extra"])
    assert message == "Usage: symphony check [--config <path-to-symphony.yml>]"

    assert {{:error, ^message}, ""} = check(["--port", "4000"])
  end

  test "lists check in the service usage" do
    assert {:error, message} = CLI.evaluate(["--bogus"])
    assert message =~ "symphony check [--config <path-to-symphony.yml>]"
  end

  describe "Config.format_error/1" do
    test "renders YAML parse errors for workflow files readably" do
      error = %YamlElixir.ParsingError{line: 2, column: 3, type: :x, message: "Bad indent"}

      assert Config.format_error({:workflow_parse_error, error}) ==
               "Failed to parse WORKFLOW.md: Bad indent (line: 2, column: 3)"
    end

    test "keeps inspecting non-YAML parse reasons" do
      assert Config.format_error({:symphony_parse_error, :eof}) == "Failed to parse symphony.yml: :eof"
    end

    test "falls back to inspect for reasons without a dedicated message" do
      assert Config.format_error(:missing_linear_api_token) == ":missing_linear_api_token"
    end
  end

  defp check(args, overrides \\ []) do
    parent = self()

    deps =
      %{
        check_config: &Config.validate_repo_workflows/0,
        file_regular?: &File.regular?/1,
        init: fn _args -> flunk("init called") end,
        set_symphony_file_path: &Workflow.set_symphony_file_path/1,
        set_state_root: fn _path -> flunk("state root set") end,
        set_state_root_from_env: fn -> flunk("state root env read") end,
        set_logs_root: fn _path -> flunk("logs root set") end,
        set_logs_root_from_env: fn -> flunk("logs root env read") end,
        set_server_host_override: fn _host -> flunk("host set") end,
        set_server_port_override: fn _port -> flunk("port set") end,
        ensure_all_started: fn ->
          send(parent, :runtime_started)
          {:ok, []}
        end,
        run_one_shot: fn _identifier, _opts ->
          send(parent, :runtime_started)
          {:ok, %{}}
        end
      }
      |> Map.merge(Map.new(overrides))

    {result, output} = with_io(fn -> CLI.evaluate(["check" | args], deps) end)
    refute_received :runtime_started
    {result, output}
  end

  defp write_symphony!(root, content) do
    path = Path.join(resolved(root), "symphony.yml")
    File.write!(path, content)
    path
  end

  # macOS tmp dirs live behind a /private symlink; the CLI reports the path it expanded.
  defp resolved(root), do: File.cd!(root, &File.cwd!/0)

  defp valid_symphony(root) do
    """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: app
        workflow: #{Path.join([root, "app", "WORKFLOW.md"])}
        default: true
        route:
          team: Test
    """
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
