defmodule SymphonyElixir.ClaudeCode.RealClaudeOpenRouterTest do
  # Starts the installed `claude` binary, not a fake, through Symphony's OpenRouter launch path
  # against the OpenRouter QA stub, so no real key or paid request is involved. `test_helper.exs`
  # always excludes the `:real_claude` tag; run it with `mix test --only real_claude <this file>`
  # where `claude` is on PATH.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.OpenRouter.{Models, Stub}

  @moduletag :real_claude
  @moduletag timeout: 120_000

  @model "symphony-qa/tools-only"
  @qa_env ~w(SYMPHONY_BAR_QA_ROOT SYMPHONY_QA_OPENROUTER_URL OPENROUTER_API_KEY)

  setup do
    test_pid = self()
    {:ok, stub, port} = Stub.start_link(log: &send(test_pid, {:stub_request, &1}))
    saved_env = Map.new(@qa_env, &{&1, System.get_env(&1)})
    previous_request = Application.get_env(:symphony_elixir, :openrouter_models_request)
    test_root = Path.join(System.tmp_dir!(), "symphony-real-claude-openrouter-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Stub.stop(stub)
      Application.put_env(:symphony_elixir, :openrouter_models_request, previous_request)
      Models.clear_cache()
      Enum.each(saved_env, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf(test_root)
    end)

    System.put_env("SYMPHONY_BAR_QA_ROOT", Path.join(test_root, "qa-root"))
    System.put_env("SYMPHONY_QA_OPENROUTER_URL", Stub.url(port))
    System.put_env("OPENROUTER_API_KEY", Stub.valid_key())
    # The models check before launch reads the stub's catalog too.
    Application.put_env(:symphony_elixir, :openrouter_models_request, fn url, opts -> Req.get(url, opts) end)
    Models.clear_cache()

    %{test_root: test_root, stub_url: Stub.url(port)}
  end

  test "a real claude run through the OpenRouter launch path accepts the stub's canned answer", %{test_root: test_root, stub_url: stub_url} do
    claude = System.find_executable("claude")
    assert claude, "claude is not on PATH"
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "QA-OPENROUTER")
    # A throwaway HOME keeps the run off the operator's Claude config, history and login.
    home = Path.join(test_root, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(home)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude",
      agent_command: claude
    )

    profile = %{kind: :implementation, model: @model, effort: nil, provider: "openrouter"}
    extra_env = %{"HOME" => home, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"}
    test_pid = self()
    on_message = fn message -> send(test_pid, {:claude_message, message}) end

    log =
      capture_log(fn ->
        assert {:ok, session} = AppServer.start_session(workspace, run_profile: profile, extra_env: extra_env)

        try do
          # `{:ok, _}` means `claude` exited with status 0 after a completed turn.
          assert {:ok, result} =
                   AppServer.run_turn(session, "Reply with one short sentence.", %{identifier: "QA-OPENROUTER"}, on_message: on_message)

          send(test_pid, {:turn_result, result})
        after
          AppServer.stop_session(session)
        end
      end)

    # Symphony records the turn: the session, the stub's canned answer and its token counts.
    assert_received {:turn_result, result}
    canned_answer = "The OpenRouter QA stub answered for model #{@model}."
    assert_received {:claude_message, {:session_started, session_id}}
    assert is_binary(session_id) and result.session_id == session_id
    assert_received {:claude_message, {:agent_text, ^canned_answer}}
    assert_received {:claude_message, {:turn_completed, %{output_tokens: 1} = turn}}
    assert turn.input_tokens >= 1

    stub_log = drain_stub_requests()
    # The models check before launch reads the public catalog, which takes no key.
    assert "OpenRouter stub: GET /api/v1/models key=rejected status=200" in stub_log
    assert "OpenRouter stub: POST /api/v1/messages model=#{@model} key=accepted status=200" in stub_log
    refute Enum.any?(stub_log, &(&1 =~ "/messages" and &1 =~ "key=rejected"))

    [started] = Regex.run(~r/Started agent [^\n]*command=[^\n]*/, log)
    assert started =~ claude

    IO.puts("""

    Real claude run through the OpenRouter stub (#{stub_url}):
    $ #{claude} --version
    #{claude_version(claude)}
    #{started}
    model: #{@model}
    exit: 0
    session: #{session_id}
    answer: #{canned_answer}
    tokens: input=#{turn.input_tokens} output=#{turn.output_tokens}
    stub request log:
    #{Enum.map_join(stub_log, "\n", &("  " <> &1))}
    """)
  end

  defp drain_stub_requests(lines \\ []) do
    receive do
      {:stub_request, line} -> drain_stub_requests([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end

  defp claude_version(claude) do
    {version, 0} = System.cmd(claude, ["--version"], stderr_to_stdout: true)
    String.trim(version)
  end
end
