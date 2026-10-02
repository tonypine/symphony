defmodule Mix.Tasks.PrBody.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check

  import ExUnit.CaptureIO

  @template """
  ## References

  - <!-- Ticket and related links -->

  ## This PR

  - <!-- What changed and why -->

  ## Important facts

  - <!-- Optional: risks and follow-ups -->

  ## Stack

  - <!-- Optional: stacked PRs -->
  """

  @valid_body """
  ## References

  - Ticket: TP-1

  ## This PR

  Nothing changes on screen.

  - First change.

  ## Important facts

  - A follow-up is tracked in TP-2.

  ## Stack

  - Builds on #1.
  """

  @minimal_body """
  ## References

  - Ticket: TP-1

  ## This PR

  - First change.

  Generated footer.
  """

  setup do
    Mix.Task.reenable("pr_body.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix pr_body.check --file /path/to/pr_body.md"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["lint", "--wat"])
    end
  end

  test "fails when file option is missing" do
    assert_raise Mix.Error, ~r/Missing required option --file/, fn ->
      Check.run(["lint"])
    end
  end

  test "fails when template is missing" do
    in_temp_repo(fn ->
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/Unable to read PR template/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when template has no headings" do
    in_temp_repo(fn ->
      write_template!("no headings here")
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/No markdown headings found/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when body file is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      assert_raise Mix.Error, ~r/Unable to read missing\.md/, fn ->
        Check.run(["lint", "--file", "missing.md"])
      end
    end)
  end

  test "fails when body still has placeholders" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @template)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "PR description still contains template placeholder comments"
    end)
  end

  test "fails when heading is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_heading = String.replace(@valid_body, "## This PR\n\nNothing changes on screen.\n\n- First change.\n\n", "")
      File.write!("body.md", missing_heading)

      assert lint_errors() =~ "Missing required heading: ## This PR"
    end)
  end

  test "fails for the previous Context/TL;DR/Test Plan format" do
    in_temp_repo(fn ->
      write_template!(@template)

      File.write!("body.md", """
      #### Context

      Context text.

      #### Test Plan

      - [x] Ran targeted checks.
      """)

      error_output = lint_errors()
      assert error_output =~ "Missing required heading: ## References"
      assert error_output =~ "Missing required heading: ## This PR"
    end)
  end

  test "fails when headings are out of order" do
    in_temp_repo(fn ->
      write_template!(@template)

      File.write!("body.md", """
      ## This PR

      - First change.

      ## References

      - Ticket: TP-1
      """)

      assert lint_errors() =~ "Required headings are out of order."
    end)
  end

  test "fails when optional headings are out of order" do
    in_temp_repo(fn ->
      write_template!(@template)

      File.write!("body.md", """
      ## References

      - Ticket: TP-1

      ## This PR

      - First change.

      ## Stack

      - Builds on #1.

      ## Important facts

      - A follow-up is tracked in TP-2.
      """)

      assert lint_errors() =~ "Required headings are out of order."
    end)
  end

  test "fails on empty section" do
    in_temp_repo(fn ->
      write_template!(@template)

      empty_references = String.replace(@valid_body, "- Ticket: TP-1", "")
      File.write!("body.md", empty_references)

      assert lint_errors() =~ "Section cannot be empty: ## References"
    end)
  end

  test "fails when a middle section is blank before the next heading" do
    in_temp_repo(fn ->
      write_template!(@template)

      File.write!("body.md", """
      ## References

      - Ticket: TP-1

      ## This PR


      ## Stack

      - Builds on #1.
      """)

      assert lint_errors() =~ "Section cannot be empty: ## This PR"
    end)
  end

  test "fails when an optional section is present but empty" do
    in_temp_repo(fn ->
      write_template!(@template)

      File.write!("body.md", @minimal_body <> "\n## Stack\n\n")

      assert lint_errors() =~ "Section cannot be empty: ## Stack"
    end)
  end

  test "fails when bullet expectations are not met" do
    in_temp_repo(fn ->
      write_template!(@template)

      File.write!("body.md", """
      ## References

      Ticket TP-1.

      ## This PR

      Not a bullet.

      ## Important facts

      Also not a bullet.
      """)

      error_output = lint_errors()
      assert error_output =~ "Section must include at least one bullet item: ## References"
      assert error_output =~ "Section must include at least one bullet item: ## This PR"
      assert error_output =~ "Section must include at least one bullet item: ## Important facts"
    end)
  end

  test "fails when heading has no content delimiter" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "## References\n- Ticket: TP-1")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
          Check.run(["lint", "--file", "body.md"])
        end
      end)
    end)
  end

  test "fails when heading appears at end of file" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "## References")

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: ## References"
    end)
  end

  test "passes for valid body" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @valid_body)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "passes when optional sections are omitted" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @minimal_body)

      assert capture_io(fn -> Check.run(["lint", "--file", "body.md"]) end) =~ "PR body format OK"
    end)
  end

  test "repository template accepts a References and This PR body" do
    template = File.read!(".github/pull_request_template.md")

    in_temp_repo(fn ->
      write_template!(template)
      File.write!("body.md", @minimal_body)

      assert capture_io(fn -> Check.run(["lint", "--file", "body.md"]) end) =~ "PR body format OK"
    end)
  end

  defp lint_errors do
    capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "validate-pr-body-task-test-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp write_template!(content) do
    File.mkdir_p!(".github")
    File.write!(".github/pull_request_template.md", content)
  end
end
