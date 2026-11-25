defmodule SymphonyElixir.QaAgent.StepPromptsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaAgent.StepPrompts

  @playbook File.read!(Path.expand("../../../priv/qa_playbooks/macos_app.md", __DIR__))
  # A session told to wait by itself: a shell sleep, or a wait of so many seconds with no tool.
  @self_wait ~r/sleep \d|\bwait (about )?\d+ seconds/i

  defp prompt(id), do: StepPrompts.prompt("macos_app", id) |> String.replace(~r/\s+/, " ")

  test "no macOS QA prompt tells a session to sleep: each wait names qa_wait_check" do
    texts = [{"the playbook", String.replace(@playbook, ~r/\s+/, " ")} | for(id <- ~w(plan walk design_check review), do: {id, prompt(id)})]

    for {name, text} <- texts do
      refute text =~ @self_wait, "#{name} tells a session to wait by itself"
      assert text =~ "qa_wait_check", "#{name} names no qa_wait_check"
    end

    assert prompt("walk") =~ "call `qa_wait_check` with `seconds: 10` after a window opens"
    assert prompt("walk") =~ "When the app exited, call `qa_wait_check` with `seconds: 10`"
    assert prompt("design_check") =~ "let it settle (`qa_wait_check` with `seconds: 10`"
    assert prompt("plan") =~ "never write `sleep` or a shell command into a brief"
  end

  test "the step prompts and the playbook name the drag, crop and measure tools, and the app's own values first" do
    for {name, text, tools} <- [
          {"walk", prompt("walk"), ~w(qa_drag qa_crop qa_measure)},
          {"design_check", prompt("design_check"), ~w(qa_crop qa_measure)},
          {"plan", prompt("plan"), ~w(qa_drag qa_crop qa_measure)},
          {"review", prompt("review"), ~w(qa_drag)},
          {"the playbook", @playbook, ~w(qa_drag qa_crop qa_measure)}
        ],
        tool <- tools do
      assert text =~ "`#{tool}`", "#{name} names no #{tool}"
    end

    for text <- [prompt("walk"), prompt("design_check"), String.replace(@playbook, ~r/\s+/, " ")] do
      assert text =~ "a picture is for how a thing looks" or text =~ "A picture is for how a thing looks"
      assert text =~ "`qa_ax_tree`'s frames"
    end

    refute prompt("plan") =~ "(such as a drag)"
  end

  # TP-1677: names come from the app's report, a scroll reaches a name, a measure reads the app's frames.
  test "plan and walk sessions take names from qa_elements, scroll by name and measure named elements; pictures stay for looks" do
    playbook = String.replace(@playbook, ~r/\s+/, " ")

    for {name, text, tools} <- [
          {"plan", prompt("plan"), ~w(qa_elements qa_scroll_to qa_measure_elements)},
          {"walk", prompt("walk"), ~w(qa_elements qa_scroll_to qa_measure_elements)},
          {"design_check", prompt("design_check"), ~w(qa_elements qa_measure_elements)},
          {"review", prompt("review"), ~w(qa_measure_elements)},
          {"the playbook", playbook, ~w(qa_elements qa_scroll_to qa_measure_elements)}
        ],
        tool <- tools do
      assert text =~ "`#{tool}`", "#{name} names no #{tool}"
    end

    assert prompt("plan") =~ "never by a name found by searching the code"
    assert prompt("walk") =~ "Take element names from `qa_elements`"
    assert prompt("walk") =~ "never from a search of the code; bring a named element into view with `qa_scroll_to`"
    assert prompt("walk") =~ "a size, a gap or an alignment between named elements with `qa_measure_elements`"
    assert prompt("design_check") =~ "`qa_measure` the edges in the picture only for what the app does not report"
    assert playbook =~ "A value the app holds is read from the app, never judged by eye"
    assert playbook =~ "the page shown, the selection and the focus from `app_state`"

    # The playbook quotes the app's naming scheme, so a plan names elements without the code.
    # Every page QA walks has names: Home, the Inbox, the ticket page, Tickets, Initiatives, Providers, Settings.
    for pattern <-
          ~w(queue-row-<ticket> done-row-<ticket> queue-drop-line queue-done-count recently-done-head recently-done-range slot-card-<slot> slot-line-<slot> sidebar-<title>) ++
            ~w(section-<title> inbox-drawer inbox-review-<ticket> inbox-action-<title> decision-<n> ticket-head ticket-timeline step-<title> ticket-connected) ++
            ~w(tickets-row-<ticket> initiative-card-<ticket> initiative-row-<ticket> provider-card-<id> settings-row-<label>) do
      assert playbook =~ "`#{pattern}`", "the playbook's QA names lack #{pattern}"
    end

    # Pictures stay for how a thing looks; qa_hover and qa_scroll keep their entries.
    assert playbook =~ "`qa_crop` and `qa_measure` are for that"
    assert playbook =~ "`qa_scroll`: scrolls the list or scroll view at an element"
  end

  # TP-1678: a cursor step is judged by the cursor the app reports it set, with its element.
  test "the walk prompt and the playbook judge the cursor by the one the app reports, with no image matching" do
    playbook = String.replace(@playbook, ~r/\s+/, " ")
    texts = [{"the playbook", playbook} | for(id <- ~w(plan walk design_check review), do: {id, prompt(id)})]

    for {name, text} <- texts do
      refute text =~ "cursor_unreadable", "#{name} still speaks of cursor_unreadable"
      refute text =~ "named cursors", "#{name} still speaks of matching the system's named cursors"
    end

    assert prompt("walk") =~ "judge a cursor step by `qa_hover`'s `cursor` and `cursor_element`, the cursor the app reports it set"
    assert prompt("walk") =~ "an `unrecorded` cursor is a finding, not a block"
    assert playbook =~ "Its `cursor` is the cursor the app reports it set at the pointer, read from the app's own cursor report in its QA root, never from an image"
    assert playbook =~ "`cursor_element` is the named element that set it"
    assert playbook =~ "`none` (no element set one: the arrow, the system's default)"
    assert playbook =~ "An `unrecorded` cursor is a finding"
    assert playbook =~ "judge the result's `cursor` and `cursor_element`, the cursor the app reports it set there"
  end
end
