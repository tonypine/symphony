defmodule SymphonyElixir.PathUnlockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentSandboxConfig, Decisions, PathUnlock, Questions}
  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Config.Schema.Agent.NetworkAccess
  alias SymphonyElixir.HumanActions.PlainWords

  @path "config/settings_ui_exempt.yml"
  @grant "Unlock config/settings_ui_exempt.yml for TP-760 so the run can drop the human_actions.label exemption."

  @request %{
    title: "Change the agents' shared guides",
    question: "May TP-760 change the agents' shared guides?",
    why: "The guide lives there.",
    if_unanswered: "TP-760 waits.",
    recommendation_reason: "It is what the ticket needs.",
    options: [
      %{label: "Allow this ticket to change the agents' shared guides", effect: "the next run changes them", recommended: true, unlocks: [".agents/skills"]},
      %{label: "Keep them as they are", effect: "nothing changes"}
    ]
  }

  setup do
    :ok = RunStore.clear()
  end

  describe "grants/1" do
    test "reads a grant from a recorded decision, and from a ruling the poll read before it is recorded" do
      issue = issue("TP-760", description([entry("comment-1", "Teach Symphony to unlock the list."), entry("ruling-c2", @grant)]))

      assert [%{id: "ruling-c2:" <> @path, decision: "D2", path: @path, answer: @grant}] = PathUnlock.grants(issue)

      ruling = Decisions.entry("ruling-c3", ~D[2026-10-14], nil, nil, "Unlock `WORKFLOW.md` for tp-760 too.")
      issue = %{issue | rulings: [ruling, entry("ruling-c2", @grant)]}

      assert [%{decision: "D2", path: @path}, %{id: "ruling-c3:WORKFLOW.md", decision: "ruling", path: "WORKFLOW.md"}] =
               PathUnlock.grants(issue)
    end

    test "ignores Linear's escapes, backticks and links around the path" do
      for text <- [
            "Unlock `config/settings\\_ui\\_exempt.yml` for TP-760.",
            "unlock ./config/settings_ui_exempt.yml for TP-760",
            "Unlock **[config/settings_ui_exempt.yml](<https://example.com/x>)** for TP-760"
          ] do
        assert PathUnlock.granted_paths(text, "TP-760") == [@path], text
      end
    end

    test "a decision cannot unlock a path outside the agent-protected list" do
      for text <- [
            "Unlock lib/symphony_elixir/agent_sandbox_config.ex for TP-760",
            "Unlock .git for TP-760",
            "Unlock ~/.zshrc for TP-760",
            "Unlock config for TP-760",
            "Unlock ../config/settings_ui_exempt.yml for TP-760"
          ] do
        assert PathUnlock.granted_paths(text, "TP-760") == [], text
        refute PathUnlock.grant_text?(text), text
        assert PathUnlock.grants(issue("TP-760", description([entry("ruling-c1", text)]))) == []
      end

      # Even a list handed straight to the sandbox can only lift workspace-protected paths.
      assert AgentSandboxConfig.unlocked_entries([".git", "~/.zshrc", "lib/app.ex", nil, " ./#{@path} "]) == ["./#{@path}"]
      assert "./.git" in AgentSandboxConfig.deny_write_paths([".git", "~/.zshrc"])
      assert "~/.zshrc" in AgentSandboxConfig.deny_write_paths([".git", "~/.zshrc"])
      assert AgentSandboxConfig.unlocked_entries(:nonsense) == []
    end

    test "a grant names its own ticket: a decision copied onto another ticket unlocks nothing there" do
      assert PathUnlock.grants(issue("TP-761", description([entry("ruling-c1", @grant)]))) == []
      assert PathUnlock.granted_paths(@grant, "TP-761") == []
      assert PathUnlock.granted_paths(nil, "TP-760") == []
      assert PathUnlock.grants(%{description: description([entry("ruling-c1", @grant)])}) == []
    end

    test "grant_text?/1 tells a grant apart from a mention of the path" do
      assert PathUnlock.grant_text?(@grant)
      refute PathUnlock.grant_text?("Only a person edits config/settings_ui_exempt.yml.")
      refute PathUnlock.grant_text?(nil)
    end
  end

  describe "grants by option" do
    test "an option with unlocks picked from the Inbox grants its paths for that ticket, so the next run may write them" do
      request = %{options: [%{label: "Allow this ticket to change the workflow settings file", unlocks: ["WORKFLOW.md"]}, %{label: "Keep it as it is"}]}
      unlocks = PathUnlock.picked_paths(request, ["Allow this ticket to change the workflow settings file"])
      picked = Decisions.entry("comment-1", ~D[2026-10-20], "Change the workflow settings", "Allow it?", "Allow this ticket to change the workflow settings file", unlocks)
      issue = issue("TP-760", description([picked]))

      assert [%{id: "comment-1:WORKFLOW.md", decision: "D1", path: "WORKFLOW.md"}] = PathUnlock.grants(issue)
      assert PathUnlock.grants(%{issue | identifier: "TP-761"}) == PathUnlock.grants(issue)

      granted = PathUnlock.claim(issue, "repo-a", run_id: "run-1")
      assert PathUnlock.paths(granted) == ["WORKFLOW.md"]
      refute "./WORKFLOW.md" in AgentSandboxConfig.deny_write_paths(PathUnlock.paths(granted))
    end

    test "an answered Question grants its picked option's paths with no Decisions section, labelled by the stored decision" do
      ticket = {:ticket, "repo-a", "issue-TP-760"}
      {:ok, question} = Questions.ask(ticket, @request, request: true)
      {:ok, _answered} = Questions.answer(ticket, question.id, "Allow this ticket to change the agents' shared guides")
      issue = issue("TP-760", "No decisions yet.")

      assert [%{id: id, decision: "question", path: ".agents/skills", answer: "Allow this ticket to change the agents' shared guides"}] = PathUnlock.grants(issue)
      assert id == question.id <> ":.agents/skills"

      # The decision recorded under the request comment the Question's row names labels the grant.
      entry = Decisions.entry("comment-7", ~D[2026-11-03], "Guides", "May it?", "Allow this ticket to change the agents' shared guides", [".agents/skills"])
      :ok = RunStore.update_ticket_state(issue.id, %{decisions: [entry], projected: %{comments: %{question.id => %{comment: "comment-7"}}}})

      assert [%{decision: "D1", path: ".agents/skills"}] = PathUnlock.grants(issue)
      assert PathUnlock.prompt_section(PathUnlock.grants(issue)) =~ "by decision D1"

      # Another ticket's runs stay locked.
      assert PathUnlock.grants(issue("TP-761", "No decisions yet.")) == []
    end

    test "a Question answered with no option, or one that unlocks nothing, grants nothing" do
      ticket = {:ticket, "repo-a", "issue-TP-760"}
      {:ok, kept} = Questions.ask(ticket, @request, request: true)
      {:ok, _answered} = Questions.answer(ticket, kept.id, "Keep them as they are")
      {:ok, free} = Questions.ask(ticket, %{@request | title: "Another"}, request: true)
      {:ok, _answered} = Questions.answer(ticket, free.id, "Do something else entirely")

      assert PathUnlock.grants(issue("TP-760", "No decisions yet.")) == []
      assert PathUnlock.grants(%{identifier: "TP-760", description: "No id."}) == []
    end

    test "prompt_section/1 names a Question's grant as a person's answer" do
      assert PathUnlock.prompt_section([%{id: "q:WORKFLOW.md", decision: "question", path: "WORKFLOW.md", answer: "Allow it"}]) =~
               "- `WORKFLOW.md`, by a person's answer to a question on this ticket"
    end

    test "only the protected paths a recorded option names count" do
      picked = Map.put(Decisions.entry("comment-1", ~D[2026-10-20], "t", "q", "Allow it"), :unlocks, ["lib/app.ex", ".git", "WORKFLOW.md"])
      assert [%{path: "WORKFLOW.md"}] = PathUnlock.grants(issue("TP-760", description([picked])))
    end

    test "picked_paths/2 reads the one option an answer picks, by label or by number alone" do
      request = %{
        options: ["**Allow the change** (recommended): TP-7 may change it", "**Drop the change in Rework**: the ticket moves to Rework"],
        unlocks: [["WORKFLOW.md", "lib/app.ex"], []]
      }

      for answer <- ["Allow the change", "**allow the change**, thanks", "1", "Option 1", "#1.", "1. Allow?\n   **Decision:** Allow the change"] do
        assert PathUnlock.picked_paths(request, [answer]) == ["WORKFLOW.md"], answer
      end

      for answer <- ["Drop the change in Rework", "2", "3", "0", "Don't allow the change", "no, never allow the change", "Something else", nil] do
        assert PathUnlock.picked_paths(request, [answer]) == [], inspect(answer)
      end

      # An answer that picks both options, or answers that disagree, pick none.
      assert PathUnlock.picked_paths(request, ["Allow the change or drop the change in Rework"]) == []
      assert PathUnlock.picked_paths(request, ["Allow the change", "2"]) == []
      assert PathUnlock.picked_paths(%{options: [%{label: "Allow", unlocks: ["WORKFLOW.md"]}, 42]}, ["allow"]) == ["WORKFLOW.md"]
    end

    test "grant_text?/1 also catches the hidden line that carries an option's paths" do
      assert PathUnlock.grant_text?("<!-- symphony:unlocks option=1 WORKFLOW.md -->")
      assert PathUnlock.grant_text?("text\n  <!--symphony:UNLOCKS WORKFLOW.md -->")
      refute PathUnlock.grant_text?("<!-- symphony:decision:c1 -->")
    end

    test "protected/1 and unprotected/1 split paths by the protected list" do
      assert PathUnlock.protected(["./WORKFLOW.md", " .agents/skills ", "lib/app.ex", "WORKFLOW.md", 3]) == ["WORKFLOW.md", ".agents/skills"]
      assert PathUnlock.protected(nil) == []
      assert PathUnlock.unprotected(["./WORKFLOW.md", "lib/app.ex", ".git", "~/.zshrc"]) == ["lib/app.ex", ".git", "~/.zshrc"]
    end

    test "every protected path has a plain description, which names no file" do
      for path <- AgentSandboxConfig.workspace_protected_paths() do
        description = PathUnlock.describe(path)
        refute description == PathUnlock.describe("lib/unknown.ex"), path
        assert PlainWords.tokens(description) == [], description
      end

      assert PathUnlock.describe("lib/unknown.ex") == "a file agents may change only with your permission"
      assert PathUnlock.describe_all(["WORKFLOW.md"]) == "the workflow settings file, which runs commands on your Mac"

      assert PathUnlock.describe_all([".agents/skills", "mise.toml", ".agents/skills", "symphony.yml"]) ==
               "the agents' instructions; the tool versions file, which picks the language versions the repo builds with and the repo's Symphony settings"
    end
  end

  describe "claim/3" do
    test "a ticket with a recorded unlock decision builds sandbox settings without that path, and another ticket's still deny it" do
      granted = PathUnlock.claim(issue("TP-760", description([entry("ruling-c1", @grant)])), "repo-a", run_id: "run-1")
      other = PathUnlock.claim(issue("TP-761", description([entry("ruling-c1", @grant)])), "repo-a", run_id: "run-2")

      assert PathUnlock.paths(granted) == [@path]
      assert other == []

      refute denied?(PathUnlock.paths(granted))
      assert denied?(PathUnlock.paths(other))
    end

    test "the unlock is the ticket's: every later run keeps it, and the record names the run that first used it" do
      issue = issue("TP-760", description([entry("ruling-c1", @grant)]))

      assert [%{path: @path}] = PathUnlock.claim(issue, "repo-a", run_id: "run-1")
      assert [%{path: @path}] = PathUnlock.claim(issue, "repo-a", run_id: "run-2")
      assert %{path_unlocks: [%{id: "ruling-c1:" <> @path, run_id: "run-1"}]} = RunStore.get_ticket_state(issue.id)
    end

    test "a ticket without a grant costs no store call, and a store that can't record the claim unlocks nothing" do
      defmodule FailingStore do
        def claim_path_unlocks(_repo_key, _issue_id, _ids, _run_id), do: {:error, :store_down}
      end

      assert PathUnlock.claim(issue("TP-760", "No decisions."), "repo-a", run_store: FailingStore) == []

      log =
        capture_log(fn ->
          assert PathUnlock.claim(issue("TP-760", description([entry("ruling-c1", @grant)])), "repo-a", run_store: FailingStore) == []
        end)

      assert log =~ "Failed to claim path unlocks; the run keeps every protection issue_identifier=TP-760 reason=:store_down"
    end
  end

  test "prompt_section/1 names each unlocked path and the decision, with the decision's words as untrusted text" do
    assert PathUnlock.prompt_section([]) == nil

    section =
      PathUnlock.prompt_section([
        %{id: "a", decision: "D2", path: @path, answer: @grant},
        %{id: "b", decision: "ruling", path: "WORKFLOW.md", answer: @grant}
      ])

    assert section =~ "Protected paths unlocked for this run:"
    assert section =~ "- `#{@path}`, by decision D2"
    assert section =~ "- `WORKFLOW.md`, by a ruling in a comment"
    assert section =~ "<linear_issue_decisions>"
    assert length(String.split(section, @grant)) == 2
  end

  # Whether every runtime's sandbox still denies writing `@path` with `unlocked` lifted.
  defp denied?(unlocked) do
    claude = ClaudeAppServer.build_claude_settings(%NetworkAccess{mode: "block"}, [], [], [], unlocked_paths: unlocked)
    {:ok, srt} = AgentSandboxConfig.srt_settings("block", [], [], [], unlocked_paths: unlocked)
    codex = AgentSandboxConfig.codex_config_overrides("block", [], [], [], workspace: "/work/TP-760", unlocked_paths: unlocked)
    legacy_codex = AgentSandboxConfig.codex_config_overrides("block", [], [], [], unlocked_paths: unlocked)

    checks = [
      "./#{@path}" in get_in(claude, ["sandbox", "filesystem", "denyWrite"]),
      "Edit(./#{@path})" in get_in(claude, ["permissions", "deny"]),
      "./#{@path}" in get_in(srt, ["filesystem", "denyWrite"]),
      Enum.any?(codex, &String.contains?(&1, ~s("/work/TP-760/#{@path}"="read"))),
      Enum.any?(legacy_codex, &String.contains?(&1, ~s("#{@path}"="read")))
    ]

    assert Enum.uniq(checks) in [[true], [false]], "runtimes disagree: #{inspect(checks)}"
    hd(checks)
  end

  defp issue(identifier, description),
    do: %Issue{id: "issue-#{identifier}", identifier: identifier, title: "Remove the label", state: "Rework", description: description}

  defp entry(key, answer), do: Decisions.entry(key, ~D[2026-10-14], nil, "Ruling given in a comment.", answer)

  defp description(entries) do
    {:ok, description} = Decisions.put("## Why\n\nDrop the setting.", entries)
    description
  end
end
