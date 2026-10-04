defmodule SymphonyElixir.HumanActions.CiSecretsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, CiSecrets}
  alias SymphonyElixir.Linear.Client

  @fake_value "ghp_" <> String.duplicate("A1b2", 9)

  # Answers from the test process's dictionary and reports every call, so a test sees each GitHub
  # request the read makes.
  defmodule FakeGitHub do
    def list_branch_runs(repo, branch, _opts) do
      send(self(), {:list_runs, repo, branch})
      Process.get(:runs)
    end

    def fetch_failed_log(run_id, opts) do
      send(self(), {:fetch_log, run_id, opts[:repo]})
      Process.get({:log, run_id}, {:ok, ""})
    end
  end

  defp run(id, workflow, conclusion, attrs \\ %{}) do
    Map.merge(
      %{id: id, workflow_name: workflow, status: "COMPLETED", conclusion: conclusion, url: "https://github.com/acme/cycle/actions/runs/#{id}", created_at: nil},
      attrs
    )
  end

  defp settings(project_slug \\ "cycle"), do: %Schema{tracker: %{%Schema{}.tracker | project_slug: project_slug}}

  defp linear(answer \\ {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"id" => "project-1", "name" => "Cycle"}, %{"name" => "no id"}]}}}}) do
    test_pid = self()

    fn query, variables, _opts ->
      assert query =~ "SymphonyHumanActionsRepoProjects"
      send(test_pid, {:projects_query, variables.filter})
      answer
    end
  end

  defp collect(cache, opts \\ []) do
    defaults = [
      settings: settings(),
      linear_client: linear(),
      github: FakeGitHub,
      github_repo: fn %{name: name} -> "acme/#{name}" end,
      base_branch: fn "cycle" -> "main" end
    ]

    CiSecrets.collect(Keyword.get(opts, :repos, [%{name: "cycle"}]), cache, Keyword.merge(defaults, opts))
  end

  describe "missing_secrets/1" do
    test "names the secrets a failed-step log says are missing" do
      log = """
      release\tSign\t2026-10-04T10:00:00.0000000Z ##[group]Run ./scripts/sign.sh
      release\tSign\t2026-10-04T10:00:00.0000000Z   MACOS_CERTIFICATE: ***
      release\tSign\t2026-10-04T10:00:01.0000000Z Error: ${{ secrets.macos_certificate }} is empty
      release\tSign\t2026-10-04T10:00:01.0000000Z secret MACOS_CERTIFICATE_PASSWORD is not set
      release\tSign\t2026-10-04T10:00:01.0000000Z ::error::Missing secret: `NOTARY_KEY`
      release\tSign\t2026-10-04T10:00:01.0000000Z missing required secret APPLE_TEAM_ID
      release\tSign\t2026-10-04T10:00:01.0000000Z The 'SLACK_WEBHOOK' secret has not been configured
      release\tSign\t2026-10-04T10:00:01.0000000Z SIGNING_KEY=#{@fake_value} secret is not set
      release\tSign\t2026-10-04T10:00:02.0000000Z Error: Process completed with exit code 1.
      """

      assert CiSecrets.missing_secrets(log) == ["MACOS_CERTIFICATE", "MACOS_CERTIFICATE_PASSWORD", "NOTARY_KEY", "APPLE_TEAM_ID", "SLACK_WEBHOOK"]
    end

    test "names nothing in a log that fails for another reason, and at most five secrets" do
      assert CiSecrets.missing_secrets("Error: test failed\n  TOKEN: ***\nthe secret is not set\n${{ secrets.TOKEN }}\n") == []

      many = Enum.map_join(1..7, "\n", &"secret KEY_#{&1} is missing")
      assert CiSecrets.missing_secrets(many) == ["KEY_1", "KEY_2", "KEY_3", "KEY_4", "KEY_5"]
    end
  end

  describe "failing_workflows/1" do
    test "lists a workflow whose two latest finished runs failed, with its latest run" do
      runs = [
        run("9", "Release", "FAILURE", %{status: "IN_PROGRESS", conclusion: nil}),
        run("8", "Release", "FAILURE"),
        run("7", "CI", "FAILURE"),
        run("6", "Release", "CANCELLED"),
        run("5", "Release", "FAILURE"),
        run("4", "CI", "SUCCESS"),
        run("3", "Deploy", "SUCCESS"),
        run("2", "Deploy", "FAILURE"),
        run("1", "Release", "FAILURE"),
        run("0", "Nightly", "FAILURE"),
        run(nil, "Nightly", "FAILURE"),
        run("x", nil, "FAILURE"),
        run("y", "Pages", "SKIPPED"),
        run("z", "Pages", "FAILURE")
      ]

      assert [%{name: "Release", latest: %{id: "8"}, failures: 3}] = CiSecrets.failing_workflows(runs)
    end
  end

  describe "collect/3" do
    test "lists each missing secret of a twice-red workflow in the repository's projects, then drops it on the next green run" do
      Process.put(:runs, {:ok, [run("8", "Release", "FAILURE"), run("7", "Release", "FAILURE"), run("6", "CI", "SUCCESS")]})
      Process.put({:log, "8"}, {:ok, "SIGNING_KEY=#{@fake_value}\nError: secret SIGNING_KEY is not set\nsecret NOTARY_KEY is missing\n"})

      {collected, cache} = collect(%{})

      assert_received {:list_runs, "acme/cycle", "main"}
      assert_received {:fetch_log, "8", "acme/cycle"}
      assert_received {:projects_query, %{"slugId" => %{"eq" => "cycle"}}}

      assert %{"project-1" => %{project: %{id: "project-1", name: "Cycle"}, actions: [signing, notary]}} = collected

      assert %Action{
               key: "ci_secret:acme/cycle:Release:SIGNING_KEY",
               kind: :ci_secret,
               title: "Add the `SIGNING_KEY` secret",
               unblocks: "the `Release` workflow on `main` in acme/cycle",
               est_minutes: 5,
               issue: nil,
               done_when: "the next run of `Release` on `main` is green.",
               steps: [
                 "Open https://github.com/acme/cycle/settings/secrets/actions (the repository's Settings → Secrets and variables → Actions).",
                 "Click New repository secret, name it `SIGNING_KEY`, and paste its value.",
                 "Re-run the failed run: https://github.com/acme/cycle/actions/runs/8"
               ]
             } = signing

      assert signing.why =~ "has failed on `main` 2 times in a row"
      assert notary.title == "Add the `NOTARY_KEY` secret"
      refute inspect(collected) =~ @fake_value

      # The same red run again: its log and the project are not read twice.
      {^collected, cache} = collect(cache)
      refute_received {:fetch_log, _run_id, _repo}
      refute_received {:projects_query, _filter}

      Process.put(:runs, {:ok, [run("9", "Release", "SUCCESS"), run("8", "Release", "FAILURE"), run("7", "Release", "FAILURE")]})
      assert {%{}, cache} = collect(cache)
      assert cache.repos["cycle"] == %{logs: %{}, actions: []}
    end

    test "lists nothing for a log that names no secret, a repository without GitHub, or one routed to no project" do
      Process.put(:runs, {:ok, [run("8", "Release", "FAILURE"), run("7", "Release", "FAILURE")]})
      Process.put({:log, "8"}, {:ok, "Error: test failed\n"})

      assert {%{}, cache} = collect(%{})
      assert_received {:list_runs, "acme/cycle", "main"}
      assert_received {:fetch_log, "8", "acme/cycle"}
      refute_received {:projects_query, _filter}

      assert {%{}, ^cache} = collect(cache)
      assert_received {:list_runs, "acme/cycle", "main"}
      refute_received {:fetch_log, _run_id, _repo}

      assert {%{}, %{}} = collect(%{}, github_repo: fn _repo -> nil end)
      refute_received {:list_runs, _repo, _branch}

      assert {%{}, %{}} = collect(%{}, settings: settings(nil))
      refute_received {:list_runs, _repo, _branch}
    end

    test "keeps a repository's last actions when GitHub or Linear cannot be read" do
      Process.put(:runs, {:ok, [run("8", "Release", "FAILURE"), run("7", "Release", "FAILURE")]})
      Process.put({:log, "8"}, {:ok, "secret SIGNING_KEY is not set"})
      {collected, cache} = collect(%{})
      assert %{"project-1" => %{actions: [_action]}} = collected

      Process.put(:runs, {:error, :gh_down})
      log = capture_log(fn -> assert {^collected, ^cache} = collect(cache) end)
      assert log =~ "could not read the failing workflows of cycle: :gh_down"

      Process.put(:runs, {:ok, [run("10", "Release", "FAILURE"), run("8", "Release", "FAILURE")]})
      Process.put({:log, "10"}, {:error, :log_gone})
      log = capture_log(fn -> assert {^collected, ^cache} = collect(cache) end)
      assert log =~ "{:failed_log_unavailable, \"10\", :log_gone}"

      Process.put(:runs, {:ok, [run("8", "Release", "FAILURE"), run("7", "Release", "FAILURE")]})
      linear_errors = linear({:ok, %{"errors" => [%{"message" => "boom"}]}})
      log = capture_log(fn -> assert {%{}, %{}} = collect(%{}, linear_client: linear_errors) end)
      assert log =~ "linear_projects_query_failed"
    end

    test "names each repository's own secrets page, and lists a secret once per project" do
      Process.put(:runs, {:ok, [run("8", "Release", "FAILURE", %{url: nil}), run("7", "Release", "FAILURE")]})
      Process.put({:log, "8"}, {:ok, "secret SIGNING_KEY is not set"})
      github_repo = fn %{name: name} -> "github.example.com/acme/#{name}" end
      repos = [%{name: "cycle"}, %{name: "cycle"}]

      assert {%{"project-1" => %{actions: [action]}}, _cache} = collect(%{}, repos: repos, github_repo: github_repo)

      assert action.steps == [
               "Open https://github.example.com/acme/cycle/settings/secrets/actions (the repository's Settings → Secrets and variables → Actions).",
               "Click New repository secret, name it `SIGNING_KEY`, and paste its value."
             ]
    end
  end

  test "routes a repository to its own projects, else the tracker's project, else none" do
    tracker = %{project_slug: "cycle"}

    by_name_or_slug = %{"or" => [%{"name" => %{"in" => ["Web"]}}, %{"slugId" => %{"in" => ["Web"]}}]}
    assert Client.repo_project_filter(%{name: "web", projects: ["Web"]}, tracker) == {:ok, by_name_or_slug}
    assert Client.repo_project_filter(%{name: "web"}, tracker) == {:ok, %{"slugId" => %{"eq" => "cycle"}}}
    assert Client.repo_project_filter(%{name: "web"}, %{project_slug: nil}) == :none
  end
end
