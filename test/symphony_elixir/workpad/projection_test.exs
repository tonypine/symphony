defmodule SymphonyElixir.Workpad.ProjectionTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{RunStore, TicketEvents, Workpad}
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixir.Workpad.Projection

  @build_log "https://uploads.linear.app/acme/build.log"
  @steps [
    %{id: "code", title: "Write the code", mode: "delegated"},
    %{id: "build", title: "Build", mode: "machine"},
    %{id: "tests", title: "Run the tests", mode: "machine"},
    %{id: "handoff", title: "Push and hand off", mode: "delegated"}
  ]

  defp event(type, payload, opts \\ []) do
    %Event{type: type, payload: payload, run_id: Keyword.get(opts, :run_id, "run-1"), artifacts: Keyword.get(opts, :artifacts, [])}
  end

  defp step(id, title, mode), do: %{step_id: id, title: title, mode: mode}

  # A run that wrote the code, built, failed its tests back to the code, and is writing the code again.
  defp events do
    [
      event("step.started", step("code", "Write the code", "delegated")),
      event("step.completed", Map.merge(step("code", "Write the code", "delegated"), %{outcome: "passed", duration_ms: 720_000})),
      event("step.started", Map.put(step("build", "Build", "machine"), :command, "mix compile --warnings-as-errors")),
      event("step.completed", Map.merge(step("build", "Build", "machine"), %{outcome: "passed", duration_ms: 240_000}), artifacts: ["art-build"]),
      event("step.started", Map.put(step("tests", "Run the tests", "machine"), :command, "mix test `test/x_test.exs`")),
      event(
        "step.completed",
        Map.merge(step("tests", "Run the tests", "machine"), %{outcome: "failed", duration_ms: 90_000, returns_to: "code", returns_to_title: "Write the code"}),
        artifacts: ["art-tests"]
      ),
      event("step.started", step("code", "Write the code", "delegated"))
    ]
  end

  defp link("art-build"), do: @build_log
  defp link(_id), do: nil

  defp rendered(events \\ events()), do: Projection.render(events, &link/1, @steps)

  defp bootstrap, do: Workpad.bootstrap_body("## Symphony Workpad", "/ws/TP-1", hostname_result: {:ok, ~c"host"}, short_sha: "abc1234", now: ~U[2026-11-05 09:00:00Z])

  defp notes(body), do: body |> String.split("### Notes") |> List.last()

  describe "render/3" do
    test "the Plan is the newest run's step list with each step's outcome and time, and the step it is on" do
      assert rendered().plan ==
               Enum.join(
                 [
                   "### Plan",
                   "",
                   "_Symphony writes this section from the run's steps._",
                   "",
                   "**Now:** Write the code.",
                   "",
                   "- [ ] Write the code: running",
                   "- [x] Build: passed, 4 min",
                   "- [ ] Run the tests: failed, 2 min, back to Write the code",
                   "- [ ] Push and hand off"
                 ],
                 "\n"
               )
    end

    test "the Validation lists each machine step's command, result and output link" do
      assert rendered().validation ==
               Enum.join(
                 [
                   "### Validation",
                   "",
                   "_Symphony writes this section from the machine steps' results._",
                   "",
                   "- [x] Build `mix compile --warnings-as-errors`: passed, 4 min · [output](#{@build_log})",
                   "- [ ] Run the tests `mix test 'test/x_test.exs'`: failed, 2 min, back to Write the code"
                 ],
                 "\n"
               )
    end

    test "a paused step, a skipped one, a run that ended and one still running read as such" do
      events = [
        event("step.completed", Map.merge(step("checks", "Checks", "machine"), %{outcome: "skipped", reason: "no Elixir changed"})),
        event("step.started", Map.put(step("build", "Build", "machine"), :command, "make")),
        event("step.completed", Map.merge(step("build", "Build", "machine"), %{outcome: "paused", question_id: "q-1", duration_ms: 30_000}))
      ]

      assert %{plan: plan, validation: validation} = Projection.render(events, &link/1)
      assert plan =~ "**Now:** paused on your answer at Build.\n\n- [x] Checks: skipped: no Elixir changed\n- [ ] Build: paused on your answer"
      assert validation =~ "- [x] Checks: skipped: no Elixir changed\n- [ ] Build `make`: paused on your answer"

      ended = events ++ [event("step.completed", Map.merge(step("tests", "Tests", "machine"), %{outcome: "failed", returns_to: "end", duration_ms: 10}))]
      assert Projection.render(ended, &link/1).plan =~ "**Now:** between steps, Tests ended last.\n"
      assert Projection.render(ended, &link/1).plan =~ "- [ ] Tests: failed, under a minute, the run ended"

      running = [event("step.started", Map.put(step("build", nil, "machine"), :command, "make"))]
      assert %{plan: plan, validation: validation} = Projection.render(running, &link/1)
      assert plan =~ "**Now:** build.\n\n- [ ] build: running"
      assert validation =~ "- [ ] build `make`: running"

      odd = [
        event("step.completed", %{"step_id" => "x", "title" => "X", "mode" => "delegated", "outcome" => "odd"}),
        event("step.completed", %{step_id: "y", outcome: "failed"}),
        event("step.completed", %{step_id: "z", title: "  ", mode: "machine", outcome: "skipped"}),
        event("step.started", %{step_id: "w", title: "W", mode: "machine"})
      ]

      assert %{plan: plan, validation: validation} = Projection.render(odd, &link/1)
      assert plan =~ "- [ ] X: odd\n- [ ] y: failed\n- [x] z: skipped\n- [ ] W: running"
      assert validation =~ "- [x] z: skipped\n- [ ] W: running"
      assert Projection.render([event("step.completed", %{outcome: "passed"})], &link/1).plan =~ "**Now:** between steps, a step ended last."
    end

    test "only the newest run is the Plan, while the Validation keeps each machine step's last result" do
      older = [event("step.completed", Map.merge(step("build", "Build", "machine"), %{outcome: "passed", duration_ms: 60_000}), run_id: "run-0")]
      newer = [event("step.started", step("code", "Write the code", "delegated"), run_id: "run-2")]

      assert %{plan: plan, validation: validation} = Projection.render(older ++ newer, &link/1)
      refute plan =~ "Build"
      assert validation =~ "- [x] Build: passed, 1 min"
      assert Projection.render(newer, &link/1).validation == nil
    end

    test "nothing to show without step events; free text cannot open or close a marker" do
      assert Projection.render([event("note", %{text: "x"})], &link/1) == %{plan: nil, validation: nil}

      events = [event("step.completed", Map.merge(step("code", "Fix <!-- symphony:workpad:plan:end --> it", "delegated"), %{outcome: "passed"}))]
      refute Projection.render(events, &link/1).plan =~ "-->"
    end
  end

  describe "put/2" do
    test "replaces only the Plan and Validation sections of the bootstrap, Notes and Confusions byte for byte" do
      body = bootstrap() <> "\n- 2026-11-05 my own note, *with* `markdown`\n"
      projected = Projection.put(body, rendered())

      assert notes(projected) == notes(body)
      assert projected =~ "### Acceptance Criteria\n\n- [ ] Derived from the Linear issue description and comments."
      refute projected =~ "Reconcile this bootstrap workpad"
      refute projected =~ "targeted tests: `<pending>`"
      assert projected =~ "abc1234\n```\n\n<!-- symphony:workpad:plan:start:"
      assert projected =~ "- [ ] Push and hand off\n<!-- symphony:workpad:plan:end -->\n\n### Acceptance Criteria"
      assert projected =~ "back to Write the code\n<!-- symphony:workpad:validation:end -->\n\n### Notes"
      assert Projection.put(projected, rendered()) == projected
      assert Projection.put(projected, %{plan: nil, validation: nil}) == projected
    end

    test "a Linear markdown rewrite of the sections does not duplicate one, and is not written again while the steps are the same" do
      projected = Projection.put(bootstrap(), rendered())

      # Linear stores `- ` items as `* `, escapes underscores and adds blank lines.
      linear =
        projected
        |> String.replace("\n- [", "\n* [")
        |> String.replace("_Symphony writes", "\\_Symphony writes")
        |> String.replace("<!-- symphony:workpad:plan:end -->", "\n<!-- symphony:workpad:plan:end -->")

      assert Projection.put(linear, rendered()) == linear

      more = rendered(events() ++ [event("step.completed", Map.merge(step("code", "Write the code", "delegated"), %{outcome: "passed", duration_ms: 60_000}))])
      again = Projection.put(linear, more)

      assert length(String.split(again, "### Plan")) == 2
      assert length(String.split(again, "### Validation")) == 2
      assert again =~ "- [x] Write the code: passed, 1 min"
      assert notes(again) == notes(linear)
    end

    test "a repeated block is dropped, and a start marker with no end ends at its own line" do
      projected = Projection.put(bootstrap(), rendered())
      [plan_block] = Regex.run(~r/<!-- symphony:workpad:plan:start:\w+ -->.*?<!-- symphony:workpad:plan:end -->/s, projected)
      doubled = String.replace(projected, "### Notes", plan_block <> "\n### Notes")

      assert Projection.put(doubled, rendered()) == projected
      assert doubled |> Projection.put(rendered(events() |> Enum.take(2))) |> String.split("### Plan") |> length() == 2

      # A stray start marker before an intact block takes only its own line, never the Notes after it.
      with_stray = String.replace(projected, "### Acceptance Criteria", "<!-- symphony:workpad:validation:start --> stray\n\n### Acceptance Criteria")
      assert with_stray |> Projection.put(rendered(Enum.take(events(), 4))) |> notes() == notes(projected)
      assert with_stray |> Projection.put(rendered(Enum.take(events(), 4))) |> String.split("### Validation") |> length() == 2

      stray = "## Symphony Workpad\n\n<!-- symphony:workpad:plan:start --> old\n\n### Notes\n\n- mine\n"
      assert Projection.put(stray, %{plan: "### Plan\n\nnew", validation: nil}) =~ "<!-- symphony:workpad:plan:start:"
      assert Projection.put(stray, %{plan: "### Plan\n\nnew", validation: nil}) =~ "new\n<!-- symphony:workpad:plan:end -->\n\n### Notes\n\n- mine\n"

      # A start marker on the body's last line, with no line break after it, ends at the body's end.
      last = Projection.put("## Symphony Workpad\n\n### Notes\n\n- mine\n<!-- symphony:workpad:plan:start -->", %{plan: "### Plan\n\nnew", validation: nil})
      assert last =~ ~r/\A## Symphony Workpad\n\n### Notes\n\n- mine\n<!-- symphony:workpad:plan:start:\w+ -->\n### Plan\n\nnew\n<!-- symphony:workpad:plan:end -->\z/
    end

    test "a workpad without the sections gets them before the next section there is, or at the end" do
      body = "## Symphony Workpad\n\n### Notes\n\n- mine\n"
      projected = Projection.put(body, rendered())

      assert projected =~
               ~r/\A## Symphony Workpad\n\n<!-- symphony:workpad:plan:start:\w+ -->\n### Plan.*plan:end -->\n\n<!-- symphony:workpad:validation:start:\w+ -->.*validation:end -->\n\n### Notes\n\n- mine\n\z/s

      assert Projection.put("## Symphony Workpad", %{plan: "### Plan\n\nx", validation: nil}) =~
               ~r/\A## Symphony Workpad\n\n<!-- symphony:workpad:plan:start:\w+ -->\n### Plan\n\nx\n<!-- symphony:workpad:plan:end -->\n\z/

      assert Projection.put("### Plan\n\n- [ ] mine", %{plan: "### Plan\n\nx", validation: nil}) =~ ~r/\A<!-- symphony:workpad:plan:start:\w+ -->\n### Plan\n\nx\n<!-- symphony:workpad:plan:end -->\z/
    end

    test "a restart's superseded copy loses the markers, and the fresh sections are the ones projected" do
      projected = Projection.put(bootstrap(), rendered())
      restarted = Workpad.supersede_body("## Symphony Workpad", projected, 1, "2026-11-05T10:00:00Z")

      refute restarted =~ "symphony:workpad:"
      assert restarted =~ "#### Plan"

      again = Projection.put(restarted, rendered())
      assert again =~ "#### Plan\n\n_Symphony writes this section"
      assert again =~ ~r/### Superseded — attempt 1.*#### Validation.*<!-- symphony:workpad:plan:start:\w+ -->\n### Plan/s
      refute again =~ "Reconcile this bootstrap workpad"
      assert Projection.strip_markers(again) =~ "### Plan\n\n_Symphony writes"
    end
  end

  describe "project_now/2 and project_later/2" do
    setup do
      :ok = RunStore.clear()
      issue_id = "issue-projection-#{System.unique_integer([:positive])}"
      {:ok, issue_id: issue_id}
    end

    defp linear_settings! do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "token", agent_kind: "claude")
      Config.settings!()
    end

    defp record_steps!(issue_id) do
      {:ok, _event} = TicketEvents.record("repo-a", issue_id, "step.started", Map.put(step("build", "Build", "machine"), :command, "make"), run_id: "run-1")
      {:ok, _event} = TicketEvents.record("repo-a", issue_id, "step.completed", Map.merge(step("build", "Build", "machine"), %{outcome: "passed", duration_ms: 1_000}), run_id: "run-1")
    end

    # Answers the comments query with `comments` and reports each comment update to `recipient`.
    defp client(recipient, comments) do
      fn query, variables, _opts ->
        cond do
          String.contains?(query, "SymphonyAgentIssueComments") ->
            {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => comments}}}}}

          String.contains?(query, "SymphonyAgentUpdateComment") ->
            send(recipient, {:updated, variables})
            {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
        end
      end
    end

    # Waits for the projection task `project_later/2` started to end.
    defp await_projection({:ok, pid}) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    defp workpad_comment(body), do: %{"id" => "comment-workpad", "body" => body, "user" => %{"name" => "Symphony"}}

    test "writes the step events into the ticket's workpad once, leaving a person's comment alone", %{issue_id: issue_id} do
      settings = linear_settings!()
      record_steps!(issue_id)
      comments = [workpad_comment(String.trim_trailing(bootstrap())), %{"id" => "comment-human", "body" => "Looks good", "user" => %{"name" => "Reporter"}}]
      opts = [settings: settings, linear_client: client(self(), comments), link: fn _id -> nil end, steps: @steps]

      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id}, opts)

      assert_received {:updated, %{id: "comment-workpad", body: body}}
      assert body =~ "- [x] Build: passed, under a minute"
      assert body =~ "- [x] Build `make`: passed, under a minute"
      # The comment is read as Linear returns it, without its trailing newline.
      assert notes(body) == String.trim_trailing(notes(bootstrap()))

      # Linear now holds the projected body: projecting the same steps again writes nothing.
      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id}, Keyword.put(opts, :linear_client, client(self(), [workpad_comment(body)])))
      refute_received {:updated, _variables}
    end

    test "no step event, no workpad, or a tracker other than Linear writes nothing", %{issue_id: issue_id} do
      settings = linear_settings!()
      unused = fn _query, _variables, _opts -> flunk("Linear must not be read") end

      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id}, settings: settings, linear_client: unused)

      record_steps!(issue_id)
      other_comment = client(self(), [%{"id" => "c", "body" => "hi"}])
      opts = [settings: settings, linear_client: other_comment, link: fn _id -> nil end]
      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id}, opts)
      refute_received {:updated, _variables}

      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude")
      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id}, linear_client: unused)
      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id})
      assert :ok = Projection.project_now({:ticket, "repo-a", issue_id}, settings: %{}, linear_client: unused)
    end

    test "projections of one ticket take turns, and another ticket's never waits on them", %{issue_id: issue_id} do
      settings = linear_settings!()
      other_id = issue_id <> "-other"
      record_steps!(issue_id)
      record_steps!(other_id)
      test = self()

      # Reports entering the projection's Linear read under `tag`, then holds it until released.
      blocking = fn tag ->
        fn _query, _variables, _opts ->
          send(test, {:entered, tag, self()})

          receive do
            :release -> {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}
          end
        end
      end

      project = fn id, tag -> Task.async(fn -> Projection.project_now({:ticket, "repo-a", id}, settings: settings, linear_client: blocking.(tag)) end) end

      first = project.(issue_id, :first)
      assert_receive {:entered, :first, first_pid}, 5_000
      second = project.(issue_id, :second)
      other = project.(other_id, :other)

      # The other ticket's projection runs while the first holds its ticket's lock.
      assert_receive {:entered, :other, other_pid}, 5_000
      send(other_pid, :release)
      assert :ok = Task.await(other)
      refute_received {:entered, :second, _pid}

      send(first_pid, :release)
      assert :ok = Task.await(first)
      assert_receive {:entered, :second, second_pid}, 5_000
      send(second_pid, :release)
      assert :ok = Task.await(second)
    end

    test "lock_id/1 locks the ticket for the calling process" do
      assert Projection.lock_id("issue-1") == {{Projection, "issue-1"}, self()}
    end

    test "a failed read is the projection's error", %{issue_id: issue_id} do
      settings = linear_settings!()
      record_steps!(issue_id)
      failing = fn _query, _variables, _opts -> {:error, :boom} end

      ticket = {:ticket, "repo-a", issue_id}
      assert {:error, _reason} = Projection.project_now(ticket, settings: settings, linear_client: failing)
    end

    test "project_later/2 projects in a task of its own and logs a failure", %{issue_id: issue_id} do
      settings = linear_settings!()
      record_steps!(issue_id)
      recipient = self()

      ticket = {:ticket, "repo-a", issue_id}
      workpad = client(recipient, [workpad_comment(bootstrap())])
      opts = [settings: settings, linear_client: workpad, link: fn _id -> nil end]
      await_projection(Projection.project_later(ticket, opts))
      assert_received {:updated, %{id: "comment-workpad"}}

      log =
        capture_log(fn ->
          failing = fn _query, _variables, _opts -> {:error, :boom} end
          await_projection(Projection.project_later(ticket, settings: settings, linear_client: failing))
          bad_steps = [settings: settings, linear_client: failing, steps: :not_a_list]
          await_projection(Projection.project_later(ticket, bad_steps))
        end)

      assert log =~ "Failed to project the workpad of issue_id=#{issue_id}: "
      assert log =~ "Failed to project the workpad of issue_id=#{issue_id}: protocol Enumerable not implemented"
    end
  end
end
