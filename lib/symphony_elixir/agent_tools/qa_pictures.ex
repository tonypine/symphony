defmodule SymphonyElixir.AgentTools.QaPictures do
  @moduledoc """
  Taking a picture records it: a picture `qa_screenshot`, `qa_gallery` (with an `entry`) or
  `qa_crop` saves under `qa-evidence/` is put on the current ticket's record by the tool call
  itself, as one `evidence` event, through the same path `ticket_record` takes
  (`SymphonyElixir.AgentTools.TicketLedger.record/3`): Symphony fills the run, its kind and the
  workspace head, the files are kept as the event's artifacts, and every check runs before
  anything is written. The run makes no second call for a picture.

  The event is nested (`parent`) under the `step.started` of the QA step that was running when the
  picture was taken: the run's newest step started and not yet completed
  (`SymphonyElixir.QaAgent.Steps` records them under the pass's run). Outside a stepped pass it has
  no parent. Its caption says what the tool knows: the picture's name and windows, the Gallery
  entry, or the crop's source and rectangle, and the step.

  The tool's answer carries `recorded`, one entry per picture: its `path`, the `event_id` and its
  `artifact_id`. A Gallery picture this pass already drew (`existing: true`) was recorded when it
  was drawn: the answer names that record and no second event is written (a file found on no
  event of the run, one drawn before pictures were recorded, is recorded then).

  A picture that cannot be recorded is never answered as taken: a session with no ticket or no
  workspace takes none (`qa_picture_not_recorded`, before the driver runs), and a picture the
  record refuses is removed from `qa-evidence/` and the call fails with the record's reason, so the
  run can take it again under the same name.
  """

  alias SymphonyElixir.AgentTools.TicketLedger
  alias SymphonyElixir.Artifacts.Store
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents.Event

  @tools ~w(qa_screenshot qa_gallery qa_crop)
  @caption_limit 500
  @not_recorded "qa_picture_not_recorded"
  @note "Each picture is on the ticket's record already (`recorded`: its event and artifact). Name its path in your step's answer; never record it again with ticket_record."

  @type take :: (-> {:ok, map()} | {:error, term()})

  @doc "The qa_* tools whose pictures are recorded as they are taken."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @doc """
  Runs the picture tool `tool` with `take` (the driver's call) and records what it saved on the
  ticket `context` names (see the moduledoc). `opts` go to `TicketLedger.record/3`. A
  `qa_gallery` call with no `entry` lists the gallery, takes no picture and is answered as it is.
  """
  @spec call(TicketLedger.context(), String.t(), map(), take(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(context, tool, args, take, opts \\ []) when tool in @tools do
    if tool == "qa_gallery" and is_nil(Map.get(args, "entry")) do
      take.()
    else
      with :ok <- ready(context),
           {:ok, result} <- take.() do
        record(context, tool, args, result, opts)
      end
    end
  end

  defp ready(context) do
    case TicketLedger.current_ticket(context) do
      {:ok, _ticket} ->
        if present?(Map.get(context, :workspace)),
          do: :ok,
          else: not_recorded("No picture was taken: this session has no workspace to keep it from.")

      {:error, {:ticket_ledger, %{"message" => message}}} ->
        not_recorded("No picture was taken: it could not be put on the ticket's record. #{message}")
    end
  end

  defp record(context, tool, args, result, opts) do
    workspace = Map.fetch!(context, :workspace)
    events = run_events(context)
    {existing, new} = result |> paths(tool) |> Enum.map(&on_record(&1, workspace, events)) |> Enum.split_with(&match?({:recorded, _, _, _}, &1))
    recorded = for {:recorded, path, event_id, id} <- existing, do: entry(path, event_id, id)

    with {:ok, taken} <- write(context, {tool, args, result}, Enum.map(new, fn {:new, path} -> path end), running_step(events), opts) do
      {:ok, answer(result, recorded ++ taken)}
    end
  end

  # A call whose pictures are all on the record already writes nothing.
  defp write(_context, _call, [], _step, _opts), do: {:ok, []}

  # One event for the pictures the call took, nested under the running step.
  defp write(context, {tool, args, result}, paths, step, opts) do
    workspace = Map.fetch!(context, :workspace)
    payload = %{"caption" => caption(tool, args, result, step)}
    args = put_parent(%{"type" => "evidence", "payload" => payload, "artifacts" => Enum.map(paths, &Path.join(workspace, &1))}, step)

    case TicketLedger.record(context, args, opts) do
      {:ok, %{"event" => %{"id" => event_id, "artifacts" => artifacts}}} ->
        {:ok, paths |> Enum.zip(artifacts) |> Enum.map(fn {path, %{"id" => id}} -> entry(path, event_id, id) end)}

      {:error, reason} ->
        Enum.each(paths, &File.rm(Path.join(workspace, &1)))
        not_recorded("The picture was not put on the ticket's record, so it was removed: #{reason_text(reason)} Take it again once that is fixed.")
    end
  end

  # The pictures the tool saved, as paths relative to the worktree, with whether the gallery found
  # one this pass drew before.
  defp paths(%{"path" => path}, "qa_crop"), do: [{path, false}]
  defp paths(%{"files" => files}, _tool), do: for(%{"path" => path} = file <- files, do: {path, Map.get(file, "existing") == true})

  defp on_record({path, false}, _workspace, _events), do: {:new, path}

  defp on_record({path, true}, workspace, events) do
    with {:ok, bytes} <- File.read(Path.join(workspace, path)),
         id = Store.id(bytes),
         %Event{id: event_id} <- Enum.find(events, &(&1.type == "evidence" and id in &1.artifacts)) do
      {:recorded, path, event_id, id}
    else
      _not_recorded -> {:new, path}
    end
  end

  defp run_events(context) do
    with {:ok, ticket} <- TicketLedger.current_ticket(context),
         run_id when is_binary(run_id) <- Map.get(context, :run_id),
         events when is_list(events) <- RunStore.list_ticket_events(ticket.issue_id, run_id: run_id) do
      events
    else
      _none -> []
    end
  end

  # The run's newest step started and not completed since.
  defp running_step(events) do
    events
    |> Enum.reduce(%{}, fn
      %Event{type: "step.started", payload: %{step_id: id}} = event, open -> Map.put(open, id, event)
      %Event{type: "step.completed", payload: %{step_id: id}}, open -> Map.delete(open, id)
      _event, open -> open
    end)
    |> Map.values()
    |> Enum.max_by(& &1.seq, fn -> nil end)
  end

  defp put_parent(args, nil), do: args
  defp put_parent(args, %Event{id: id}), do: Map.put(args, "parent", id)

  defp caption(tool, args, result, step) do
    (what(tool, args, result) <> during(step)) |> String.slice(0, @caption_limit)
  end

  defp what("qa_screenshot", args, %{"files" => files}) do
    windows = files |> Enum.map(&Map.get(&1, "title")) |> Enum.filter(&present?/1)
    "Screenshot #{args["name"]}" <> if(windows == [], do: "", else: " of " <> Enum.join(windows, ", "))
  end

  defp what("qa_gallery", args, _result) do
    details = for key <- ~w(variation width appearance), present?(args[key]), do: "#{key} #{args[key]}"
    "Gallery picture of #{args["entry"]}" <> if(details == [], do: "", else: " (" <> Enum.join(details, ", ") <> ")")
  end

  defp what("qa_crop", args, result) do
    rect = Map.get(result, "rect") || %{}
    "Crop #{args["name"]} of #{result["source"]} at #{rect["x"]},#{rect["y"]}, #{rect["width"]}×#{rect["height"]} points, zoom #{result["zoom"]}"
  end

  defp during(nil), do: ""
  defp during(%Event{payload: payload}), do: ", taken during the QA step " <> payload.title

  defp entry(path, event_id, artifact_id), do: %{"path" => path, "event_id" => event_id, "artifact_id" => artifact_id}

  defp answer(result, recorded), do: Map.merge(result, %{"recorded" => recorded, "recorded_note" => @note})

  defp reason_text({:ticket_ledger, %{"message" => message}}), do: message
  defp reason_text(reason), do: inspect(reason) <> "."

  defp not_recorded(message), do: {:error, {:qa_tool, @not_recorded, message}}

  defp present?(value), do: is_binary(value) and value != ""
end
