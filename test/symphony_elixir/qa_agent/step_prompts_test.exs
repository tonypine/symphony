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
end
