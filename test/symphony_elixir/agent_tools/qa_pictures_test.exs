defmodule SymphonyElixir.AgentTools.QaPicturesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.QaPictures
  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}
  alias SymphonyElixir.Artifacts.Store
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-pictures"
  @run_id "qa-run-1"
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>

  setup do
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())

    base = Path.join(System.tmp_dir!(), "symphony-qa-pictures-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "worktree")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(base)
      File.rm_rf(Paths.artifacts_dir())
    end)

    %{workspace: workspace}
  end

  defp context(ctx, extra \\ %{}) do
    issue = %Issue{id: @issue_id, identifier: "TP-1", repo_key: @repo_key}
    Map.merge(%{issue: issue, workspace: ctx.workspace, run_id: @run_id, run_kind: "qa"}, extra)
  end

  # Stands in for the driver: saves `files` under qa-evidence/ and answers as the tool does.
  defp take(ctx, files, answer) do
    test = self()

    fn ->
      send(test, :taken)
      for {name, bytes} <- files, do: write!(ctx.workspace, "qa-evidence/" <> name, bytes)
      {:ok, answer}
    end
  end

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp step!(type, step_id, title) do
    payload = %{step_id: step_id, title: title, mode: "delegated"}
    payload = if type == "step.completed", do: Map.put(payload, :outcome, "passed"), else: payload
    {:ok, event} = TicketEvents.record(@repo_key, @issue_id, type, payload, actor: {:agent, @run_id, "qa"})
    event
  end

  defp evidence, do: RunStore.list_ticket_events(@issue_id, types: ["evidence"])

  defp git_head!(workspace) do
    git = fn args -> System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args], cd: workspace, stderr_to_stdout: true) end
    {_out, 0} = git.(["init", "-q"])
    {_out, 0} = git.(["commit", "-q", "--allow-empty", "-m", "base"])
    {head, 0} = git.(["rev-parse", "HEAD"])
    String.trim(head)
  end

  describe "taking a picture records it (TP-1681)" do
    test "a screenshot is an evidence event of the run, under the QA step running, on the workspace head, with its files as artifacts", ctx do
      head = git_head!(ctx.workspace)
      step!("step.started", "launch", "Launch the app")
      step!("step.completed", "launch", "Launch the app")
      walk = step!("step.started", "walk_1", "Walk step 1")

      files = [%{"path" => "qa-evidence/home-1.png", "title" => "Main"}, %{"path" => "qa-evidence/home-2.png", "title" => "Settings"}]
      take = take(ctx, [{"home-1.png", @png}, {"home-2.png", @png <> "2"}], %{"files" => files})

      assert {:ok, answer} = QaPictures.call(context(ctx), "qa_screenshot", %{"pid" => 1, "name" => "home"}, take)
      assert answer["files"] == files

      assert [event] = evidence()
      assert event.run_id == @run_id
      assert event.actor.run_id == @run_id
      assert event.actor.run_kind == "qa"
      assert event.head_sha == head
      assert event.parent == walk.id
      assert event.payload == %{caption: "Screenshot home of Main, Settings, taken during the QA step Walk step 1"}
      assert event.artifacts == [Store.id(@png), Store.id(@png <> "2")]
      assert {:ok, %{kind: "screenshot", label: "home-1.png", run_id: @run_id}} = Artifacts.get(Store.id(@png))

      # The answer says it was recorded, with the event and each picture's artifact.
      assert answer["recorded"] == [
               %{"path" => "qa-evidence/home-1.png", "event_id" => event.id, "artifact_id" => Store.id(@png)},
               %{"path" => "qa-evidence/home-2.png", "event_id" => event.id, "artifact_id" => Store.id(@png <> "2")}
             ]

      assert answer["recorded_note"] =~ "never record it again with ticket_record"
    end

    test "a crop and a Gallery picture are recorded with what the tool knows of them; outside a step they have no parent", ctx do
      crop = %{"path" => "qa-evidence/icon.png", "source" => "qa-evidence/home.png", "rect" => %{"x" => 2, "y" => 1, "width" => 3, "height" => 4}, "zoom" => 2}
      args = %{"path" => "qa-evidence/home.png", "name" => "icon", "x" => 2, "y" => 1, "width" => 3, "height" => 4}

      assert {:ok, %{"recorded" => [%{"path" => "qa-evidence/icon.png", "event_id" => crop_event}]}} =
               QaPictures.call(context(ctx), "qa_crop", args, take(ctx, [{"icon.png", @png}], crop))

      gallery = %{"files" => [%{"path" => "qa-evidence/button-1-dark.png"}]}

      assert {:ok, %{"recorded" => [%{"event_id" => gallery_event}]}} =
               QaPictures.call(context(ctx), "qa_gallery", %{"entry" => "button", "appearance" => "dark"}, take(ctx, [{"button-1-dark.png", @png <> "g"}], gallery))

      assert [%{id: ^crop_event, parent: nil} = cropped, %{id: ^gallery_event, parent: nil} = drawn] = evidence()
      assert cropped.payload.caption == "Crop icon of qa-evidence/home.png at 2,1, 3×4 points, zoom 2"
      assert drawn.payload.caption == "Gallery picture of button (appearance dark)"
    end

    test "a Gallery picture this pass already drew returns its record and writes no second event", ctx do
      gallery = %{"files" => [%{"path" => "qa-evidence/button-1-dark.png"}]}
      args = %{"entry" => "button"}
      assert {:ok, %{"recorded" => [first]}} = QaPictures.call(context(ctx), "qa_gallery", args, take(ctx, [{"button-1-dark.png", @png}], gallery))

      again = %{"files" => [%{"path" => "qa-evidence/button-1-dark.png", "existing" => true}]}
      assert {:ok, %{"recorded" => [^first], "files" => [%{"existing" => true}]}} = QaPictures.call(context(ctx), "qa_gallery", args, take(ctx, [], again))
      assert [%{payload: %{caption: "Gallery picture of button"}}] = evidence()

      # One drawn before pictures were recorded is on no event of the run: it is recorded now.
      write!(ctx.workspace, "qa-evidence/home-dark.png", @png <> "old")
      old = %{"files" => [%{"path" => "qa-evidence/home-dark.png", "existing" => true}]}
      assert {:ok, %{"recorded" => [%{"artifact_id" => id}]}} = QaPictures.call(context(ctx), "qa_gallery", %{"entry" => "home"}, take(ctx, [], old))
      assert id == Store.id(@png <> "old")
      assert length(evidence()) == 2
    end

    test "the Gallery's list takes no picture and is answered as it is", ctx do
      listing = %{"entries" => []}
      assert {:ok, ^listing} = QaPictures.call(%{}, "qa_gallery", %{}, take(ctx, [], listing))
      assert {:ok, ^listing} = QaPictures.call(%{}, "qa_gallery", %{"entry" => nil}, take(ctx, [], listing))
      assert evidence() == []
    end

    test "a session with no ticket or no workspace takes no picture and fails with the reason", ctx do
      take = take(ctx, [{"x.png", @png}], %{"files" => [%{"path" => "qa-evidence/x.png"}]})

      assert {:error, {:qa_tool, "qa_picture_not_recorded", message}} = QaPictures.call(%{workspace: ctx.workspace}, "qa_screenshot", %{"name" => "x"}, take)
      assert message =~ "No picture was taken"
      assert message =~ "This session has no current ticket."

      assert {:error, {:qa_tool, "qa_picture_not_recorded", message}} = QaPictures.call(context(ctx, %{workspace: nil}), "qa_screenshot", %{"name" => "x"}, take)
      assert message =~ "no workspace"

      refute_received :taken
      assert evidence() == []
    end

    test "a picture the record refuses is removed and the call fails with the record's reason", ctx do
      outside = write!(Path.join(ctx.workspace, ".."), "elsewhere.png", @png)

      planted = fn ->
        File.mkdir_p!(Path.join(ctx.workspace, "qa-evidence"))
        File.ln_s!(outside, Path.join(ctx.workspace, "qa-evidence/planted.png"))
        {:ok, %{"files" => [%{"path" => "qa-evidence/planted.png"}]}}
      end

      assert {:error, {:qa_tool, "qa_picture_not_recorded", message}} = QaPictures.call(context(ctx), "qa_screenshot", %{"name" => "planted"}, planted)
      assert message =~ "was not put on the ticket's record, so it was removed"
      assert message =~ "qa-evidence/planted.png"
      refute File.exists?(Path.join(ctx.workspace, "qa-evidence/planted.png"))
      assert File.exists?(outside)

      # A run whose events cannot name it (no run) keeps no picture either.
      take = take(ctx, [{"norun.png", @png}], %{"path" => "qa-evidence/norun.png", "source" => "qa-evidence/a.png", "zoom" => 2})
      assert {:error, {:qa_tool, "qa_picture_not_recorded", message}} = QaPictures.call(context(ctx, %{run_id: nil}), "qa_crop", %{"name" => "norun"}, take)
      assert message =~ "invalid_actor"
      refute File.exists?(Path.join(ctx.workspace, "qa-evidence/norun.png"))

      assert evidence() == []
    end

    test "a driver's error is the tool's error, and nothing is recorded", ctx do
      failing = fn -> {:error, {:qa_tool, "qa_no_window", "The app has no window on screen."}} end
      assert {:error, {:qa_tool, "qa_no_window", _message}} = QaPictures.call(context(ctx), "qa_screenshot", %{"name" => "x"}, failing)
      assert evidence() == []
    end

    test "the qa_* tools dispatch their pictures through the record, and their descriptions say so", ctx do
      issue = %Issue{id: @issue_id, identifier: "TP-1", repo_key: @repo_key}
      opts = [issue: issue, workspace: ctx.workspace, run_id: @run_id, tool_scope: :qa]

      for tool <- ["qa_screenshot", "qa_crop"] do
        # No driver: the call reaches the driver once the ticket is known.
        response = DynamicTool.execute(tool, %{"name" => "x"}, opts)
        assert %{"error" => %{"code" => "qa_driver_unavailable"}} = Jason.decode!(response["output"])

        # No ticket: no picture is taken.
        response = DynamicTool.execute(tool, %{"name" => "x"}, tool_scope: :qa, workspace: ctx.workspace)
        assert %{"error" => %{"code" => "qa_picture_not_recorded"}} = Jason.decode!(response["output"])
      end

      for tool <- QaPictures.tools() do
        spec = Enum.find(DynamicTool.tool_specs(:qa), &(&1["name"] == tool))
        assert spec["description"] =~ "Taking a picture records it", tool
        assert spec["description"] =~ "`recorded` names each picture's `path`, `event_id` and `artifact_id`", tool
        assert spec["description"] =~ "Never record it again with ticket_record", tool
        assert spec["description"] =~ "qa_picture_not_recorded", tool
      end
    end
  end
end
