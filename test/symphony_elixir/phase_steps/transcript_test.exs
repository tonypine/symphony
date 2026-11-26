defmodule SymphonyElixir.PhaseSteps.TranscriptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PhaseSteps.Transcript
  alias SymphonyElixir.TicketEvents

  @fixture Path.expand("../../fixtures/session_transcript/session.jsonl", __DIR__)
  @issue_id "issue-transcript"
  @run_id "run-transcript"
  @session_id "sess-recorded"

  setup do
    :ok = RunStore.clear()
    root = Path.join(System.tmp_dir!(), "symphony-step-transcript-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    projects = Path.join(root, "projects")
    File.mkdir_p!(workspace)
    previous = Application.get_env(:symphony_elixir, :claude_projects_dir)
    Application.put_env(:symphony_elixir, :claude_projects_dir, projects)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :claude_projects_dir, previous),
        else: Application.delete_env(:symphony_elixir, :claude_projects_dir)

      File.rm_rf(root)
    end)

    session_path = Path.join([projects, String.replace(workspace, ~r/[^A-Za-z0-9]/, "-"), @session_id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(session_path))
    %{workspace: workspace, session_path: session_path}
  end

  defp fixture_entries, do: @fixture |> File.read!() |> String.split("\n", trim: true)

  describe "a recorded session cut at each step's end" do
    test "each step's slice holds its own lines, and the slices concatenated are the session's", ctx do
      {code_entries, handoff_entries} = Enum.split(fixture_entries(), 10)

      File.write!(ctx.session_path, Enum.map_join(code_entries, &(&1 <> "\n")))
      {code, offsets} = Transcript.read_session(ctx.workspace, @session_id, %{})

      File.write!(ctx.session_path, Enum.map_join(handoff_entries, &(&1 <> "\n")), [:append])
      {handoff, offsets} = Transcript.read_session(ctx.workspace, @session_id, offsets)

      assert offsets == %{@session_id => byte_size(File.read!(@fixture))}
      assert code ++ handoff == Transcript.lines(File.read!(@fixture))

      assert [
               %{kind: "say", text: "I'll read the module first.", at: "2026-11-06T15:10:01.000Z"},
               %{kind: "tool", text: "Bash: sed -n 1,40p lib/app.ex", tool: "Bash"} = bash,
               %{kind: "result", text: "defmodule App do\n  def run, do: :ok\nend", duration_ms: 450},
               %{kind: "tool", text: "Edit: lib/app.ex", tool: "Edit", file: "lib/app.ex"},
               %{kind: "result", text: "File has not been read yet.", failed: true, duration_ms: 200},
               %{kind: "tool", text: ~s(mcp__symphony__ticket_record: {"payload":{"step_id":"code"},"type":"step.completed"}), tool: "mcp__symphony__ticket_record"},
               %{kind: "result", text: "Recorded. [image]", duration_ms: 1_000},
               %{kind: "say", text: "The code step is done."}
             ] = code

      # A call that names no file carries none.
      refute Map.has_key?(bash, :file)

      # The user's prompts, the thinking and a summary entry are no lines; neither is blank text.
      assert [%{kind: "tool", text: "mcp__symphony__github_push_branch: {}"}, %{kind: "result", text: "Pushed."}, %{kind: "say"}] = handoff
    end

    test "an entry still being written waits for the next read, and nothing new reads as nothing", ctx do
      [first, second | _rest] = fixture_entries() |> Enum.drop(2)
      File.write!(ctx.session_path, first <> "\n" <> String.slice(second, 0, 20))

      {[%{kind: "say"}], offsets} = Transcript.read_session(ctx.workspace, @session_id, %{})
      assert offsets == %{@session_id => byte_size(first) + 1}
      assert {[], ^offsets} = Transcript.read_session(ctx.workspace, @session_id, offsets)

      File.write!(ctx.session_path, first <> "\n" <> second <> "\n")
      assert {[%{kind: "tool", text: "Bash: sed -n 1,40p lib/app.ex"}], _offsets} = Transcript.read_session(ctx.workspace, @session_id, offsets)
    end

    test "a session with no transcript Symphony reads has no lines", ctx do
      assert Transcript.read_session(ctx.workspace, "sess-missing", %{"other" => 3}) == {[], %{"other" => 3}}
      assert Transcript.read_session(nil, nil, %{}) == {[], %{}}
    end
  end

  describe "the lines of an entry" do
    test "a note is kept whole, a tool with no field that says what it does shows its input, and an untimed result has no duration" do
      long = "**Done.**\n\n- one\n- two\n\n```\nmix test\n```\n" <> String.duplicate("a", 5_000)

      text =
        [
          %{type: "assistant", message: %{content: [%{type: "text", text: long}]}},
          %{
            type: "assistant",
            timestamp: "2026-11-06T15:09:00Z",
            message: %{content: [%{type: "tool_use", id: "t1", name: "Grep", input: %{pattern: "", limit: 3}}]}
          },
          %{type: "assistant", message: %{content: [%{type: "tool_use", id: "t2", name: "Odd", input: "raw"}]}},
          %{type: "user", timestamp: "not a time", message: %{content: [%{type: "tool_result", tool_use_id: "t1", content: nil}]}},
          %{type: "user", timestamp: "2026-11-06T15:10:00Z", message: %{content: [%{type: "tool_result", tool_use_id: "t2", content: [%{"no" => "type"}]}]}},
          %{type: "assistant", message: "not blocks"}
        ]
        |> Enum.map_join("\n", &Jason.encode!/1)

      assert [say, grep, odd, untimed, unstarted] = Transcript.lines(text <> "\nnot json\n")
      assert say.text == String.trim(long)
      refute Map.has_key?(say, :at)
      assert grep.text == ~s(Grep: {"limit":3,"pattern":""})
      assert odd.text == "Odd: raw"
      assert {grep.tool, odd.tool} == {"Grep", "Odd"}
      assert untimed == %{kind: "result", text: "", at: "not a time"}
      assert unstarted == %{kind: "result", text: "", at: "2026-11-06T15:10:00Z"}
    end

    test "a call's input gives what it does in short and the file it reads, writes or edits" do
      assert Transcript.tool_fields(%{"file_path" => "lib/x.ex", "content" => "x"}) == %{summary: "lib/x.ex", file: "lib/x.ex"}
      assert Transcript.tool_fields(%{"notebook_path" => "a.ipynb"}) == %{summary: ~s({"notebook_path":"a.ipynb"}), file: "a.ipynb"}
      assert Transcript.tool_fields(%{"pattern" => "x", "path" => "lib"}) == %{summary: "lib", file: "lib"}
      assert Transcript.tool_fields(%{"command" => "mix  test\n--trace"}) == %{summary: "mix test --trace"}
      assert Transcript.tool_fields("raw") == %{summary: "raw"}
      assert Transcript.tool_fields(nil) == %{summary: ""}
    end

    test "a result keeps its first lines, bounded" do
      text =
        Jason.encode!(%{
          type: "user",
          message: %{content: [%{type: "tool_result", tool_use_id: "t", is_error: true, content: "1 test, 1 failure  \r\n\n  left: :done\n" <> String.duplicate("b", 600)}]}
        })

      assert [%{kind: "result", failed: true, text: result}] = Transcript.lines(text)
      assert String.starts_with?(result, "1 test, 1 failure\n  left: :done\nbbb")
      assert String.length(result) == 501 and String.ends_with?(result, "…")
    end

    test "a step's artifact is one JSON object a line" do
      lines = [%{kind: "say", text: "Hi"}, %{kind: "result", text: "ok", duration_ms: 3}]
      encoded = Transcript.encode(lines)

      assert encoded |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1, keys: :atoms)) == lines
      assert Transcript.encode([]) == ""
    end
  end

  describe "the run now" do
    defp record_step!(type, step_id, run_id \\ @run_id) do
      payload = %{step_id: step_id, title: "Write the code", mode: "delegated"}
      payload = if type == "step.completed", do: Map.merge(payload, %{outcome: "passed", duration_ms: 1}), else: payload
      {:ok, event} = TicketEvents.record("default", @issue_id, type, payload, run_id: run_id)
      event
    end

    defp update(event, params, at), do: %{event: event, timestamp: at, payload: %{params: params}}

    test "the step the live run is on and every line of it the stream holds, each note whole" do
      started = record_step!("step.started", "code")
      before = DateTime.add(started.at, -5, :second)
      later = DateTime.add(started.at, 1, :second)

      stream =
        [
          update(:agent_text, %{msg: %{content: "From the step before"}}, before),
          %{event: :tool_use},
          update(:notification, %{}, later)
        ] ++
          Enum.flat_map(1..15, fn n ->
            [
              update(:agent_text, %{msg: %{content: "Said #{n}"}}, later),
              update(:tool_use, %{tool: "Bash"}, later),
              update(:tool_result, %{text: "out #{n}"}, later)
            ]
          end)

      assert %{current_step: step, recent_lines: lines} = Transcript.run_now(@issue_id, @run_id, stream)
      assert step == %{id: "code", title: "Write the code", mode: "delegated", started_at: DateTime.to_iso8601(started.at)}
      assert length(lines) == 45
      assert List.last(lines) == %{kind: "result", text: "out 15", at: DateTime.to_iso8601(later)}
      refute Enum.any?(lines, &(&1.text == "From the step before"))
      assert Enum.any?(lines, &match?(%{kind: "tool", text: "Bash", tool: "Bash"}, &1))
    end

    test "a live call names its tool and file as fields, a failed result says so, and a note keeps its lines" do
      started = record_step!("step.started", "code")
      at = DateTime.add(started.at, 1, :second)
      iso = DateTime.to_iso8601(at)
      note = "**Now** the tests:\n\n- one\n- two " <> String.duplicate("a", 600)

      stream = [
        update(:agent_text, %{msg: %{content: "  " <> note <> "\n"}}, at),
        update(:agent_text, %{msg: %{content: "   "}}, at),
        update(:agent_text, %{msg: %{content: nil}}, at),
        update(:tool_use, %{tool: "Write", summary: "lib/x.ex", file: "lib/x.ex"}, at),
        update(:tool_result, %{text: "1 failure\n\n  left: 1", failed: true}, at),
        update(:tool_use, %{tool: "Bash", summary: ""}, at),
        update(:tool_result, %{text: nil}, at)
      ]

      assert %{recent_lines: lines} = Transcript.run_now(@issue_id, @run_id, stream)

      assert lines == [
               %{kind: "say", text: note, at: iso},
               %{kind: "tool", text: "Write: lib/x.ex", tool: "Write", file: "lib/x.ex", at: iso},
               %{kind: "result", text: "1 failure\n  left: 1", failed: true, at: iso},
               %{kind: "tool", text: "Bash", tool: "Bash", at: iso},
               %{kind: "result", text: "", at: iso}
             ]
    end

    test "between steps, before any step, for another run and without a run, the run is on no step" do
      none = %{current_step: nil, recent_lines: []}
      assert Transcript.run_now(@issue_id, @run_id, []) == none

      record_step!("step.started", "code")
      assert Transcript.run_now(@issue_id, "run-other", []) == none
      assert Transcript.run_now(@issue_id, nil, []) == none
      assert Transcript.run_now(nil, @run_id, []) == none

      completed = record_step!("step.completed", "code")
      in_step = update(:agent_text, %{msg: %{content: "In the step"}}, DateTime.add(completed.at, -1, :second))
      hi = update(:agent_text, %{msg: %{content: "Hi"}}, DateTime.add(completed.at, 1, :second))

      # Between steps, the lines since the last step completed.
      assert Transcript.run_now(@issue_id, @run_id, [in_step, hi]) ==
               %{current_step: nil, recent_lines: [%{kind: "say", text: "Hi", at: DateTime.to_iso8601(hi.timestamp)}]}
    end

    # A QA or Code Review run walks no steps: its lines are the whole stream's.
    test "a run that walks no steps shows its lines" do
      at = DateTime.utc_now()

      stream =
        [%{event: :tool_use}] ++
          Enum.map(1..25, fn n -> update(:agent_text, %{msg: %{content: "Said #{n}"}}, at) end)

      assert %{current_step: nil, recent_lines: lines} = Transcript.run_now(@issue_id, @run_id, stream)
      assert length(lines) == 25
      assert List.last(lines) == %{kind: "say", text: "Said 25", at: DateTime.to_iso8601(at)}
      assert Transcript.run_now(nil, nil, stream).recent_lines == lines
    end
  end
end
