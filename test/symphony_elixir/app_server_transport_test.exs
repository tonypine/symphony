defmodule SymphonyElixir.AppServerTransportTest do
  use SymphonyElixir.TestSupport

  defmodule ProcessTreeProbe do
    @moduledoc false

    alias SymphonyElixir.ProcessTree

    def terminate_descendants(root_pid) do
      recipient = Application.fetch_env!(:symphony_elixir, :process_tree_probe_recipient)
      send(recipient, {:process_tree_cleanup, root_pid})
      ProcessTree.terminate_descendants(root_pid)
    end

    def terminate_port_descendants(port) do
      recipient = Application.fetch_env!(:symphony_elixir, :process_tree_probe_recipient)
      send(recipient, {:process_tree_cleanup_fallback, Port.info(port) != nil})
      # Delegate to the real cleanup so the spawned process tree is actually
      # terminated. Recording the call alone would leak the fake-codex busy
      # loop, leaving an orphaned process pinning a CPU core after the test.
      ProcessTree.terminate_port_descendants(port)
    end
  end

  test "app server times out one command even when the turn remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-command-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1003")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1003"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1003","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"cmd-timeout","type":"commandExecution","status":"running","command":"mix run --no-halt"}}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_command_timeout_ms: 10,
        agent_turn_timeout_ms: 10_000
      )

      issue = %Issue{
        id: "issue-command-timeout",
        identifier: "MT-1003",
        title: "Validate command timeout",
        description: "Ensure long-running commands cannot stream forever",
        state: "In Progress",
        url: "https://example.org/issues/MT-1003",
        labels: ["backend"]
      }

      assert {:error, {:command_timeout, details}} =
               AppServer.run(workspace, "Validate command timeout", issue)

      assert details.command == "mix run --no-halt"
      assert details.elapsed_ms >= 10
      assert details.timeout_ms == 10
    after
      File.rm_rf(test_root)
    end
  end

  test "app server times out a turn even while codex emits side output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-timeout-side-output-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1005")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1005"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1005","status":"inProgress","items":[]}}}'
            # Exit once stdout closes so sandboxed runs (where pgrep-based
            # descendant cleanup cannot enumerate processes) do not leak a
            # busy loop that outlives the test.
            while printf '%s\\n' 'ERROR codex_models_manager::manager: failed to refresh available models'; do
              sleep 0.01
            done
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_command_timeout_ms: 0,
        agent_turn_timeout_ms: 30
      )

      issue = %Issue{
        id: "issue-turn-timeout-side-output",
        identifier: "MT-1005",
        title: "Validate turn timeout",
        description: "Ensure side output cannot keep a turn alive indefinitely",
        state: "In Progress",
        url: "https://example.org/issues/MT-1005",
        labels: ["backend"]
      }

      Application.put_env(:symphony_elixir, :process_tree_probe_recipient, self())

      assert {:error, :turn_timeout} =
               AppServer.run(workspace, "Validate turn timeout with side output", issue, process_tree_module: ProcessTreeProbe)

      assert_receive {:process_tree_cleanup, root_pid} when is_integer(root_pid) and root_pid > 0
      assert_process_exits(root_pid)
    after
      Application.delete_env(:symphony_elixir, :process_tree_probe_recipient)
      File.rm_rf(test_root)
    end
  end

  test "app server clears command tracking for malformed command completion frames" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-command-completed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1004")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1004"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1004","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"cmd-malformed-complete","type":"commandExecution","status":"running","command":"rg input_tokens lib test"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-malformed-complete","type":"commandExecution","status":"completed","aggregatedOutput":"truncated output'
            sleep 0.1
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_command_timeout_ms: 20,
        agent_turn_timeout_ms: 2_000
      )

      issue = %Issue{
        id: "issue-malformed-command-completed",
        identifier: "MT-1004",
        title: "Malformed command completion",
        description: "Malformed completion frames should not keep a command marked active",
        state: "In Progress",
        url: "https://example.org/issues/MT-1004",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Validate malformed command completion", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: malformed_payload}}
      assert malformed_payload =~ ~s("method":"item/completed")
      assert malformed_payload =~ ~s("type":"commandExecution")

      assert_received {:app_server_message,
                       %{
                         event: :command_completed_recovered,
                         recovery: :malformed_command_completion
                       }}

      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server attaches redirected stderr tail to local launch exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-launch-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-LAUNCH-STDERR")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      printf '%s\\n' 'launch warning before exit' >&2
      printf '%s\\n' 'fatal: missing --verbose flag' >&2
      exit 1
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-launch-stderr",
        identifier: "MT-LAUNCH-STDERR",
        title: "Launch stderr",
        description: "Ensure launch failures carry stderr context",
        state: "In Progress",
        url: "https://example.org/issues/MT-LAUNCH-STDERR",
        labels: ["backend"]
      }

      assert {:error, {:port_exit, 1, %{stderr: stderr}}} =
               AppServer.run(workspace, "Capture launch stderr", issue)

      assert stderr =~ "launch warning before exit"
      assert stderr =~ "fatal: missing --verbose flag"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server bounds redirected stderr tails on local launch exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-launch-stderr-tail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-LAUNCH-STDERR-TAIL")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      printf '%s\\n' 'stderr line 1' >&2
      printf '%s\\n' 'stderr line 2' >&2
      printf '%s\\n' 'stderr line 3' >&2
      printf '%s\\n' 'stderr line 4' >&2
      printf '%s\\n' 'stderr line 5' >&2
      printf '%s\\n' 'stderr line 6' >&2
      exit 1
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-launch-stderr-tail",
        identifier: "MT-LAUNCH-STDERR-TAIL",
        title: "Launch stderr tail",
        description: "Ensure launch failures carry a bounded stderr tail",
        state: "In Progress",
        url: "https://example.org/issues/MT-LAUNCH-STDERR-TAIL",
        labels: ["backend"]
      }

      assert {:error, {:port_exit, 1, %{stderr: stderr}}} =
               AppServer.run(workspace, "Capture launch stderr tail", issue)

      assert stderr == Enum.map_join(2..6, "\n", &"stderr line #{&1}")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server discards trailing partial stdout fragments on exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-trailing-fragment-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-96")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-96"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-96","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s' '{"method":"turn/completed"'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-trailing-fragment",
        identifier: "MT-96",
        title: "Trailing stdout fragment",
        description: "Ensure partial stdout at process exit is ignored",
        state: "In Progress",
        url: "https://example.org/issues/MT-96",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:error, {:port_exit, 0}} =
               AppServer.run(workspace, "Ignore trailing fragment", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :turn_ended_with_error, reason: {:port_exit, 0}}}
      refute_received {:app_server_message, %{event: :malformed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server keeps JSON frames intact when codex stderr fires mid-frame" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-interleave-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-95")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-95"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-95","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s' '{"method":"turn/completed"'
            printf '%s\\n' 'codex stderr noise that would otherwise split the frame' >&2
            printf '%s\\n' ',"params":{}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr-interleave",
        identifier: "MT-95",
        title: "Stderr interleave",
        description: "Ensure codex stderr does not corrupt mid-flight stdout JSON frames",
        state: "In Progress",
        url: "https://example.org/issues/MT-95",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Stderr interleave", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "codex stderr noise that would otherwise split the frame"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server drains stdout while callbacks process previous events" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stdout-pump-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      marker_file = Path.join(test_root, "stdout-burst.done")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      marker_file="#{marker_file}"
      chunk=$(printf '%4096s' '' | tr ' ' x)
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"gate","type":"commandExecution"}}}'

            i=0
            while [ "$i" -lt 256 ]; do
              printf '{"method":"item/completed","params":{"item":{"id":"cmd-%s","type":"commandExecution","aggregatedOutput":"%s"}}}\\n' "$i" "$chunk"
              i=$((i + 1))
            done

            printf '%s\\n' '{"method":"turn/completed"}'
            printf '%s\\n' done > "$marker_file"
            sleep 1
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_turn_timeout_ms: 5_000
      )

      issue = %Issue{
        id: "issue-stdout-pump",
        identifier: "MT-99",
        title: "Stdout pump",
        description: "Ensure stdout is drained independently from event callback work",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      on_message = fn
        %{
          event: :notification,
          payload: %{"method" => "item/started", "params" => %{"item" => %{"id" => "gate"}}}
        } ->
          send(test_pid, {:callback_blocked, self()})

          receive do
            :release_callback -> :ok
          after
            3_000 -> :ok
          end

        %{event: :turn_completed} ->
          send(test_pid, :turn_completed)

        _message ->
          :ok
      end

      task = Task.async(fn -> AppServer.run(workspace, "Drain stdout burst", issue, on_message: on_message) end)

      assert_receive {:callback_blocked, callback_pid}, 5_000
      assert eventually(fn -> File.exists?(marker_file) end, 200)

      send(callback_pid, :release_callback)

      assert {:ok, _result} = Task.await(task, 5_000)
      assert_receive :turn_completed, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "srt app server launch does not source operator shell startup files" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-shell-startup-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SHELL")
      fake_home = Path.join(test_root, "home")
      marker_file = Path.join(test_root, "profile-sourced")
      srt_binary = Path.join(test_root, "fake-srt")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.mkdir_p!(fake_home)
      System.put_env("HOME", fake_home)

      File.write!(Path.join(fake_home, ".profile"), """
      touch #{marker_file}
      """)

      File.write!(srt_binary, """
      #!/bin/sh
      if [ "${1-}" = "--settings" ]; then
        shift 2
      fi

      exec "$@"
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-shell"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-shell","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(srt_binary, 0o755)
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_sandbox_runtime: %{
          kind: "srt",
          command: srt_binary
        },
        agent_turn_timeout_ms: 5_000
      )

      assert {:ok, session} = AppServer.start_session(workspace)
      assert :ok = AppServer.stop_session(session)
      refute File.exists?(marker_file)
    after
      if is_binary(previous_home) do
        System.put_env("HOME", previous_home)
      else
        System.delete_env("HOME")
      end

      File.rm_rf(test_root)
    end
  end

  test "app server fails fast when Codex reports stdout transport failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stdout-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-94")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-94"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-94","status":"inProgress","items":[]}}}'
            printf '%s\\n' '2026-05-20T09:14:16Z ERROR codex_app_server_transport::transport::stdio: Failed to write to stdout: Resource temporarily unavailable (os error 35)'
            sleep 1
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_turn_timeout_ms: 5_000
      )

      issue = %Issue{
        id: "issue-stdout-failure",
        identifier: "MT-94",
        title: "Stdout failure",
        description: "Ensure stdout transport failures do not leave the run stuck",
        state: "In Progress",
        url: "https://example.org/issues/MT-94",
        labels: ["backend"]
      }

      assert {:error, {:codex_stdio_write_failed, message}} =
               AppServer.run(workspace, "Capture stdout failure", issue)

      assert message =~ "Failed to write to stdout"
      assert message =~ "Resource temporarily unavailable"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails fast when redirected stderr reports stdout transport failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-stdout-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-98")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-98"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-98","status":"inProgress","items":[]}}}'
            printf '%s\\n' '2026-05-20T09:14:16Z ERROR codex_app_server_transport::transport::stdio: Failed to write to stdout: Resource temporarily unavailable (os error 35)' >&2
            sleep 1
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_turn_timeout_ms: 5_000
      )

      issue = %Issue{
        id: "issue-stderr-stdout-failure",
        identifier: "MT-98",
        title: "Redirected stderr stdout failure",
        description: "Ensure stderr-tail transport failures do not wait for the watchdog",
        state: "In Progress",
        url: "https://example.org/issues/MT-98",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:error, {:codex_stdio_write_failed, message}} =
               AppServer.run(workspace, "Capture redirected stderr stdout failure", issue, on_message: on_message)

      assert message =~ "Failed to write to stdout"
      assert message =~ "Resource temporarily unavailable"
      assert_received {:app_server_message, %{event: :transport_failed, reason: :codex_stdio_write_failed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server falls back to redirected stderr tail for timeout transport failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-timeout-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-98-TIMEOUT")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-98-timeout"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-98-timeout","status":"inProgress","items":[]}}}'
            printf '%s' '2026-05-20T09:14:16Z ERROR codex_app_server_transport::transport::stdio: Failed to write to stdout: Resource temporarily unavailable (os error 35)' >&2
            sleep 1
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_turn_timeout_ms: 100
      )

      issue = %Issue{
        id: "issue-stderr-timeout-fallback",
        identifier: "MT-98-TIMEOUT",
        title: "Redirected stderr timeout fallback",
        description: "Ensure timeout fallback checks redirected stderr transport failures",
        state: "In Progress",
        url: "https://example.org/issues/MT-98-TIMEOUT",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:error, {:codex_stdio_write_failed, message}} =
               AppServer.run(workspace, "Capture redirected stderr timeout fallback", issue, on_message: on_message)

      assert message =~ "Failed to write to stdout"
      assert message =~ "Resource temporarily unavailable"
      assert_received {:app_server_message, %{event: :transport_failed, reason: :codex_stdio_write_failed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats ANSI-coded codex transport errors as stdout write failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stdout-ansi-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-97")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-97"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-97","status":"inProgress","items":[]}}}'
            printf '\\033[2m2026-05-20T09:14:16.420328Z\\033[0m \\033[31mERROR\\033[0m \\033[2mcodex_app_server_transport::transport::stdio\\033[0m\\033[2m:\\033[0m Failed to write to stdout: Resource temporarily unavailable (os error 35)\\n'
            sleep 1
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stdout-ansi",
        identifier: "MT-97",
        title: "ANSI stdout failure",
        description: "Tracing-subscriber colorized errors must still trigger the transport abort",
        state: "In Progress",
        url: "https://example.org/issues/MT-97",
        labels: ["backend"]
      }

      assert {:error, {:codex_stdio_write_failed, message}} =
               AppServer.run(workspace, "Capture ANSI stdout failure", issue)

      assert message =~ "Failed to write to stdout"
      assert message =~ "Resource temporarily unavailable"
      refute message =~ "\e["
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not treat unrelated log lines mentioning stdout writes as transport failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stdout-benign-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-95")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-95"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-95","status":"inProgress","items":[]}}}'
            printf '%s\\n' '2026-05-20T09:14:16Z DEBUG codex_user_message: prior client report Failed to write to stdout resolved'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stdout-benign",
        identifier: "MT-95",
        title: "Benign stdout mention",
        description: "Ensure unrelated log lines that mention stdout writes do not abort the run",
        state: "In Progress",
        url: "https://example.org/issues/MT-95",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Benign stdout mention", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not treat malformed protocol payloads containing stdout text as transport failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stdout-payload-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-96")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-96"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-96","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"commandExecution","aggregatedOutput":"test line codex_app_server_transport::transport::stdio: Failed to write to stdout: Resource temporarily unavailable'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stdout-payload",
        identifier: "MT-96",
        title: "Stdout text in payload",
        description: "Ensure command output text is not classified as a transport failure",
        state: "In Progress",
        url: "https://example.org/issues/MT-96",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Benign stdout text in payload", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: payload}}
      assert payload =~ "codex_app_server_transport::transport::stdio"
      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :transport_failed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server trips circuit breaker after repeated identical failed command executions" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-command-failure-breaker-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-COMMAND-BREAKER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-command-breaker"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-command-breaker","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-1","type":"commandExecution","status":"failed","command":"mix test --failed"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-2","type":"commandExecution","status":"failed","command":"mix test --failed"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-3","type":"commandExecution","status":"failed","command":"mix test --failed"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        max_consecutive_identical_tool_failures: 3
      )

      assert {:error, {:tool_failure_circuit_breaker, payload}} =
               AppServer.run(workspace, "Retry command", issue!("MT-COMMAND-BREAKER"))

      assert payload.count == 3
      assert payload.threshold == 3
      assert payload.signature.kind == :command_execution
      assert payload.signature.name == "mix test --failed"
      assert is_binary(payload.signature.args_hash)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server command failure circuit breaker resets on different execution and success" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-command-failure-reset-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-COMMAND-RESET")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-command-reset"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-command-reset","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-1","type":"commandExecution","status":"failed","command":"mix test test/a_test.exs"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-2","type":"commandExecution","status":"failed","command":"mix test test/b_test.exs"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-3","type":"commandExecution","status":"failed","command":"mix test test/a_test.exs"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-4","type":"commandExecution","status":"completed","command":"mix test test/a_test.exs"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-5","type":"commandExecution","status":"failed","command":"mix test test/a_test.exs"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        max_consecutive_identical_tool_failures: 2
      )

      assert {:ok, _result} = AppServer.run(workspace, "Retry command", issue!("MT-COMMAND-RESET"))
    after
      File.rm_rf(test_root)
    end
  end

  test "app server trips circuit breaker after repeated identical failed dynamic tool calls" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-dynamic-tool-breaker-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DYNAMIC-BREAKER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dynamic-breaker"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dynamic-breaker","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"id":88,"method":"item/tool/call","params":{"name":"linear_add_comment","callId":"call-1","threadId":"thread-dynamic-breaker","turnId":"turn-dynamic-breaker","arguments":{"body":"same"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":89,"method":"item/tool/call","params":{"name":"linear_add_comment","callId":"call-2","threadId":"thread-dynamic-breaker","turnId":"turn-dynamic-breaker","arguments":{"body":"same"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        max_consecutive_identical_tool_failures: 2
      )

      tool_executor = fn _tool, _arguments -> %{"success" => false, "output" => "blocked"} end

      assert {:error, {:tool_failure_circuit_breaker, payload}} =
               AppServer.run(workspace, "Retry tool", issue!("MT-DYNAMIC-BREAKER"), tool_executor: tool_executor)

      assert payload.count == 2
      assert payload.threshold == 2
      assert payload.signature.kind == :dynamic_tool
      assert payload.signature.name == "linear_add_comment"
      assert is_binary(payload.signature.args_hash)
    after
      File.rm_rf(test_root)
    end
  end

  test "max_consecutive_identical_tool_failures zero disables app server circuit breaker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-command-failure-breaker-disabled-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-COMMAND-BREAKER-DISABLED")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-command-breaker-disabled"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-command-breaker-disabled","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-1","type":"commandExecution","status":"failed","command":"mix test --failed"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-2","type":"commandExecution","status":"failed","command":"mix test --failed"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"cmd-3","type":"commandExecution","status":"failed","command":"mix test --failed"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        max_consecutive_identical_tool_failures: 0
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Retry command", issue!("MT-COMMAND-BREAKER-DISABLED"))
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"fake-remote-codex"*)
          ;;
        *"remote"*"get-url"*"origin"*|*"branch"*"--show-current"*)
          exit 0
          ;;
        *"symphony-mcp-shim"*|*"rm -f "*|*"rm -rf "*"symphony-codex-home"*)
          exit 0
          ;;
      esac

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        agent_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert trace =~ "-T -p 2200 worker-01 bash -lc"
      assert trace =~ "cd "
      assert trace =~ remote_workspace
      assert trace =~ "exec "
      assert trace =~ "fake-remote-codex"
      assert trace =~ "--config"
      assert trace =~ "default_permissions=\"workspace_write\""
      assert trace =~ "permissions.workspace_write.filesystem="
      assert trace =~ "permissions.workspace_write.network="
      assert trace =~ "permissions.workspace_write.network.domains="
      assert trace =~ "app-server"

      # Shared skills are provisioned under the remote $CODEX_HOME/skills for user-scope discovery.
      assert trace =~ "symphony-codex-home"
      assert trace =~ "/skills/commit/SKILL.md"
      assert trace =~ "/skills/pull/SKILL.md"
      assert trace =~ "/skills/linear/SKILL.md"

      assert trace =~ ~r/ARGV:.*rm -rf.*symphony-codex-home/,
             "expected remote codex_home to be rm -rf'd on stop_session"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace, "#{remote_workspace}/.git"],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "config", "experimental_network", "enabled"]) == true &&
                     get_in(payload, [
                       "params",
                       "config",
                       "experimental_network",
                       "domains",
                       "github.com"
                     ]) == "allow"
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server attaches remote redirected stderr tail to remote launch exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-launch-stderr-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      trace_file = Path.join(test_root, "ssh-remote-stderr.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE-STDERR"

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"tail -c "*"codex.stderr.log"*)
          printf '%s\\n' 'remote stderr line 1'
          printf '%s\\n' 'remote stderr line 2'
          printf '%s\\n' 'remote stderr line 3'
          printf '%s\\n' 'remote stderr line 4'
          printf '%s\\n' 'remote stderr line 5'
          printf '%s\\n' 'remote stderr line 6'
          exit 0
          ;;
        *"fake-remote-codex"*)
          exit 1
          ;;
        *"remote"*"get-url"*"origin"*|*"branch"*"--show-current"*)
          exit 0
          ;;
        *"symphony-mcp-shim"*|*"rm -f "*|*"rm -rf "*"symphony-codex-home"*)
          exit 0
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        agent_command: "fake-remote-codex app-server"
      )

      assert {:error, {:port_exit, 1, %{stderr: stderr}}} =
               AppServer.run(remote_workspace, "Capture remote launch stderr", issue!("MT-REMOTE-STDERR"), worker_host: "worker-01")

      assert stderr == Enum.map_join(2..6, "\n", &"remote stderr line #{&1}")

      trace = File.read!(trace_file)
      assert trace =~ "codex.stderr.log"
      assert trace =~ "2>>"
      assert trace =~ "tail -c 16384"
      assert trace =~ ~r/ARGV:.*rm -rf.*symphony-codex-home/
    after
      File.rm_rf(test_root)
    end
  end

  test "stdout pump relays output and exit status of a process that exited before it connected" do
    # Regression: a fast-exiting process closed the port before Port.connect/2,
    # which raised and surfaced {:stdout_pump_connect_failed, "argument error"}.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [:binary, :exit_status, line: 1_024, args: ["-c", "printf 'early line\\n'; exit 1"]]
      )

    monitor_ref = :erlang.monitor(:port, port)
    assert_receive {:DOWN, ^monitor_ref, :port, ^port, _reason}, 5_000

    assert {:ok, %{ref: pump_ref}} = AppServer.start_stdout_pump(port)
    assert_receive {:codex_stdout_line, ^port, ^pump_ref, "early line"}, 1_000
    assert_receive {:codex_stdout_exit, ^port, ^pump_ref, 1}, 1_000
  end

  test "stdout pump reports a connect failure for a port closed without an exit status" do
    port = Port.open({:spawn_executable, System.find_executable("sh")}, [:binary, args: ["-c", "exec cat"]])
    Port.close(port)

    log =
      capture_log(fn ->
        assert {:error, {:stdout_pump_connect_failed, "argument error"}} = AppServer.start_stdout_pump(port)
      end)

    assert log =~ "Failed to start Codex stdout pump"
  end

  test "app server does not block remote launch exits on stalled stderr tail fetch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-launch-stderr-timeout-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      trace_file = Path.join(test_root, "ssh-remote-stderr-timeout.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE-STDERR-TIMEOUT"

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"tail -c "*"codex.stderr.log"*)
          sleep 3
          printf '%s\\n' 'late remote stderr'
          exit 0
          ;;
        *"fake-remote-codex"*)
          exit 1
          ;;
        *"remote"*"get-url"*"origin"*|*"branch"*"--show-current"*)
          exit 0
          ;;
        *"symphony-mcp-shim"*|*"rm -f "*|*"rm -rf "*"symphony-codex-home"*)
          exit 0
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        agent_command: "fake-remote-codex app-server"
      )

      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:port_exit, 1}} =
               AppServer.run(remote_workspace, "Capture remote launch stderr", issue!("MT-REMOTE-STDERR-TIMEOUT"), worker_host: "worker-01")

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 2_500

      trace = File.read!(trace_file)
      assert trace =~ "codex.stderr.log"
      assert trace =~ "tail -c 16384"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server discovers remote github context over ssh for dynamic tools" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-gh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      trace_file = Path.join(test_root, "ssh-remote-gh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE-GH"

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"fake-remote-codex"*)
          ;;
        *"remote"*"get-url"*"origin"*)
          printf 'DISCOVERY:origin\\n' >> "$trace_file"
          printf '%s\\n' 'git@github.example.com:acme/symphony.git'
          exit 0
          ;;
        *"branch"*"--show-current"*)
          printf 'DISCOVERY:branch\\n' >> "$trace_file"
          printf '%s\\n' 'feature/remote-gh'
          exit 0
          ;;
        *"symphony-mcp-shim"*|*"rm -f "*|*"rm -rf "*"symphony-codex-home"*)
          exit 0
          ;;
      esac

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote-gh"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote-gh","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"id":89,"method":"item/tool/call","params":{"name":"github_get_pull_request","callId":"call-remote-gh","threadId":"thread-remote-gh","turnId":"turn-remote-gh","arguments":{}}}'
            ;;
          *'"id":89'*)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        github: %{enterprise_hosts: ["github.example.com"]},
        agent_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote-gh",
        identifier: "MT-REMOTE-GH",
        title: "Remote GitHub context",
        description: "Validate ssh-backed GitHub dynamic tools",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE-GH",
        labels: ["backend"]
      }

      gh_runner = fn
        ["pr", "view", "feature/remote-gh", "--repo", "github.example.com/acme/symphony", "--json", fields], opts ->
          refute Keyword.has_key?(opts, :cd)
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3187,
             "state" => "OPEN",
             "title" => "Remote GitHub context",
             "body" => "Body",
             "url" => "https://github.example.com/acme/symphony/pull/3187",
             "headRefName" => "feature/remote-gh",
             "baseRefName" => "main"
           }), 0}
      end

      git_runner = fn _args, _opts -> flunk("remote dynamic GitHub tools should not run local git") end

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Read remote PR",
                 issue,
                 worker_host: "worker-01:2200",
                 gh_runner: gh_runner,
                 git_runner: git_runner
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert "DISCOVERY:origin" in lines
      assert "DISCOVERY:branch" in lines

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 89 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"])
                   |> Jason.decode!()
                   |> get_in(["url"])
                   |> Kernel.==("https://github.example.com/acme/symphony/pull/3187")
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "Codex default project guide list does not inject CLAUDE.md" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-codex-project-guides-default-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-GUIDES-DEFAULT")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-project-guides-default.trace")
      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "CLAUDE.md"), "Claude-only convention\n")
      File.write!(codex_binary, project_guides_fake_codex(trace_file, "default"))
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Codex prompt", issue!("MT-CODEX-GUIDES-DEFAULT"))

      assert codex_turn_prompt(trace_file) == "Codex prompt"
    after
      File.rm_rf(test_root)
    end
  end

  test "Codex injects explicit project guide files and honors disabled guide injection" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-codex-project-guides-explicit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-GUIDES-EXPLICIT")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-project-guides-explicit.trace")
      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "CLAUDE.md"), "Claude rule\n@AGENTS.md\n")
      File.write!(Path.join(workspace, "AGENTS.md"), "Agent rule\n")
      File.write!(codex_binary, project_guides_fake_codex(trace_file, "explicit"))
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_project_guide_files: ["CLAUDE.md"]
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Codex explicit prompt", issue!("MT-CODEX-GUIDES-EXPLICIT"))

      prompt = codex_turn_prompt(trace_file)
      assert prompt =~ "Codex explicit prompt\n\n## Project conventions"
      assert prompt =~ "### CLAUDE.md"
      assert prompt =~ "Claude rule"
      assert prompt =~ "### @AGENTS.md"
      assert prompt =~ "Agent rule"

      File.rm!(trace_file)
      File.write!(codex_binary, project_guides_fake_codex(trace_file, "disabled"))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_project_guide_files: ["CLAUDE.md"],
        agent_include_project_guides: false
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Codex disabled prompt", issue!("MT-CODEX-GUIDES-DISABLED"))

      assert codex_turn_prompt(trace_file) == "Codex disabled prompt"
    after
      File.rm_rf(test_root)
    end
  end

  defp project_guides_fake_codex(trace_file, suffix) do
    """
    #!/bin/sh
    trace_file="#{trace_file}"
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"id":1'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-guides-#{suffix}"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-guides-#{suffix}","status":"inProgress","items":[]}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
      esac
    done
    """
  end

  defp codex_turn_prompt(trace_file) do
    trace_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find_value(&turn_prompt_from_trace_line/1)
  end

  defp turn_prompt_from_trace_line("JSON:" <> encoded) do
    encoded
    |> Jason.decode!()
    |> turn_prompt_from_payload()
  end

  defp turn_prompt_from_trace_line(_line), do: nil

  defp turn_prompt_from_payload(%{"id" => 3} = payload) do
    get_in(payload, ["params", "input", Access.at(0), "text"])
  end

  defp turn_prompt_from_payload(_payload), do: nil

  defp issue!(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Project guides",
      description: "Ensure project guide prompt injection behaves by runner",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  describe "compact_notification_payload/2" do
    @threshold 8_192

    test "passes small payloads through with the original raw bytes intact" do
      small = String.duplicate("a", 100)
      payload = command_completion_payload(%{"aggregatedOutput" => small})
      raw = "<original-raw>"

      assert {^payload, ^raw} = AppServer.compact_notification_payload(payload, raw)
    end

    test "leaves payloads at the byte-size threshold unchanged" do
      exactly = String.duplicate("a", @threshold)
      payload = command_completion_payload(%{"aggregatedOutput" => exactly})

      assert {^payload, "raw"} = AppServer.compact_notification_payload(payload, "raw")
    end

    test "trims large aggregatedOutput while preserving head and tail markers" do
      head_marker = String.duplicate("A", 200)
      tail_marker = String.duplicate("Z", 200)
      middle = String.duplicate("M", @threshold * 2)
      original = head_marker <> middle <> tail_marker
      payload = command_completion_payload(%{"aggregatedOutput" => original})

      assert {compacted, raw} = AppServer.compact_notification_payload(payload, "ignored")

      trimmed = get_in(compacted, ["params", "item", "aggregatedOutput"])
      assert String.starts_with?(trimmed, head_marker)
      assert String.ends_with?(trimmed, tail_marker)
      assert trimmed =~ "[truncated"
      assert byte_size(trimmed) < byte_size(original)
      # Raw must round-trip through Jason so downstream consumers see the trimmed shape.
      assert Jason.decode!(raw) == compacted
    end

    test "round-trips multibyte UTF-8 payloads without dropping back to original raw" do
      # 4-byte codepoints; cutting at 4096 bytes will land mid-codepoint unless the helper pulls
      # back to a boundary.
      utf8 = String.duplicate("🐙", div(@threshold, 4) + 10)
      payload = command_completion_payload(%{"aggregatedOutput" => utf8})

      assert {compacted, raw} = AppServer.compact_notification_payload(payload, "<unused>")

      trimmed = get_in(compacted, ["params", "item", "aggregatedOutput"])
      assert String.valid?(trimmed)
      assert trimmed =~ "[truncated"
      # Raw must reflect the compacted payload, not the original raw, when compaction happened.
      assert Jason.decode!(raw) == compacted
      refute raw == "<unused>"
    end

    test "trims every aliased noisy field on the item" do
      large = String.duplicate("x", @threshold * 2)

      for field <- ~w(aggregatedOutput aggregated_output output stdout stderr diff) do
        payload = command_completion_payload(%{field => large})

        assert {compacted, _raw} = AppServer.compact_notification_payload(payload, "raw")

        trimmed = get_in(compacted, ["params", "item", field])
        assert byte_size(trimmed) < byte_size(large), "#{field} should have been trimmed"
        assert trimmed =~ "[truncated"
      end
    end

    test "leaves values just over the threshold alone when truncation would inflate the field" do
      # head + tail + marker can exceed the input when the input is only marginally over the cap.
      barely = String.duplicate("y", @threshold + 1)
      payload = command_completion_payload(%{"aggregatedOutput" => barely})

      assert {^payload, "raw"} = AppServer.compact_notification_payload(payload, "raw")
    end

    test "leaves non-string fields alone even when an aliased key exists" do
      payload = command_completion_payload(%{"aggregatedOutput" => %{"unexpected" => "shape"}})

      assert {^payload, "raw"} = AppServer.compact_notification_payload(payload, "raw")
    end

    defp command_completion_payload(item_fields) do
      %{
        "method" => "item/completed",
        "params" => %{
          "item" =>
            Map.merge(
              %{"id" => "cmd-1", "type" => "commandExecution", "status" => "completed"},
              item_fields
            )
        }
      }
    end
  end

  describe "flush_stderr_transport_messages/1" do
    test "drains stale codex_stderr_transport_failed messages so the next turn is not poisoned" do
      port = open_flush_test_port()

      try do
        send(self(), {:codex_stderr_transport_failed, port, make_ref(), {:codex_stdio_write_failed, "stale 1"}})
        send(self(), {:codex_stderr_transport_failed, port, make_ref(), {:codex_stdio_write_failed, "stale 2"}})

        assert :ok = AppServer.flush_stderr_transport_messages(port)

        refute_received {:codex_stderr_transport_failed, ^port, _ref, _reason}
      after
        close_flush_test_port(port)
      end
    end

    test "leaves unrelated messages and messages for other ports in the mailbox" do
      port = open_flush_test_port()
      other_port = open_flush_test_port()

      try do
        send(self(), {:other_message, :keep_me})
        send(self(), {:codex_stderr_transport_failed, other_port, make_ref(), {:codex_stdio_write_failed, "different port"}})
        send(self(), {:codex_stderr_transport_failed, port, make_ref(), {:codex_stdio_write_failed, "drained"}})

        assert :ok = AppServer.flush_stderr_transport_messages(port)

        assert_received {:other_message, :keep_me}
        assert_received {:codex_stderr_transport_failed, ^other_port, _ref, _reason}
        refute_received {:codex_stderr_transport_failed, ^port, _ref, _reason}
      after
        close_flush_test_port(port)
        close_flush_test_port(other_port)
      end
    end
  end

  defp open_flush_test_port do
    Port.open({:spawn, "cat"}, [:binary, :exit_status])
  end

  defp close_flush_test_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp eventually(fun, attempts)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp assert_process_exits(os_pid) when is_integer(os_pid) and os_pid > 0 do
    assert eventually(fn -> not os_pid_alive?(os_pid) end, 200)
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _exception -> false
  end
end
