defmodule SymphonyElixir.GitHub.CiLogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.CiLog

  @repo "acme/app"
  @run_url "https://github.com/acme/app/actions/runs/101"

  # A `gh` that answers from `answers` (`fn args -> {output, status} end`) and reports each call.
  defp gh(answers) do
    recipient = self()

    fn args, _opts ->
      send(recipient, {:gh, args})
      answers.(args)
    end
  end

  # The answers of a repository with run 101: a failed `test` job (201) and a green `lint` job (202).
  defp answers(overrides \\ %{}) do
    fn args ->
      case Map.fetch(overrides, args) do
        {:ok, answer} -> answer
        :error -> default_answer(args)
      end
    end
  end

  defp default_answer(["run", "view", "101", "-R", @repo, "--json", _fields]), do: json(run_payload())
  defp default_answer(["api", "repos/acme/app/actions/jobs/201"]), do: json(job_payload("201", "failure"))
  defp default_answer(["api", "repos/acme/app/actions/jobs/202"]), do: json(job_payload("202", "success"))
  defp default_answer(["api", "repos/acme/app/check-runs/" <> _annotations]), do: json(annotations())
  defp default_answer(["run", "view", "--job", "201", "--log-failed", "-R", @repo]), do: {log(5), 0}
  defp default_answer(["run", "view", "--job", "202", "--log", "-R", @repo]), do: {"lint\tRun credo\t2026-10-20T06:30:00.000Z ok\n", 0}
  defp default_answer(["run", "view", "--job", "201", "--log", "-R", @repo]), do: {log(5), 0}

  defp json(payload), do: {Jason.encode!(payload), 0}

  defp run_payload(attrs \\ %{}) do
    Map.merge(
      %{
        "databaseId" => 101,
        "url" => @run_url,
        "workflowName" => "CI",
        "jobs" => [
          %{
            "databaseId" => 201,
            "name" => "test",
            "conclusion" => "failure",
            "url" => @run_url <> "/job/201",
            "steps" => [%{"name" => "Set up job", "conclusion" => "success"}, %{"name" => "Verify app bundle", "conclusion" => "failure"}]
          },
          %{"databaseId" => 202, "name" => "lint", "conclusion" => "success", "url" => @run_url <> "/job/202", "steps" => []}
        ]
      },
      attrs
    )
  end

  defp job_payload(id, conclusion, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => String.to_integer(id),
        "run_id" => 101,
        "name" => if(id == "201", do: "test", else: "lint"),
        "conclusion" => conclusion,
        "html_url" => @run_url <> "/job/" <> id,
        "steps" => [%{"name" => "Verify app bundle", "conclusion" => conclusion}]
      },
      attrs
    )
  end

  defp annotations do
    [
      %{"annotation_level" => "failure", "path" => ".github", "start_line" => 26, "title" => "", "message" => "Process completed with exit code 1.\nSee the log."},
      %{"annotation_level" => "warning", "message" => "Node 16 is deprecated"},
      "not an annotation"
    ]
  end

  # `count` lines of `gh run view --log-failed`, the last one the cause.
  defp log(count) do
    lines = for n <- 1..(count - 1), do: "test\tVerify app bundle\t2026-10-20T06:30:0#{rem(n, 10)}.123Z line #{n}"
    Enum.join(lines ++ ["test\tVerify app bundle\t2026-10-20T06:31:00.000Z printf: write error: Broken pipe"], "\n") <> "\n"
  end

  defp read(target, opts \\ [], overrides \\ %{}) do
    CiLog.read(@repo, target, Keyword.merge([gh_runner: gh(answers(overrides))], opts))
  end

  describe "target/1" do
    test "takes exactly one of run_id, job_id and pr_number, as a number or a string of digits" do
      assert CiLog.target(%{"run_id" => 101}) == {:ok, {:run, "101"}}
      assert CiLog.target(%{"job_id" => "201"}) == {:ok, {:job, "201"}}
      assert CiLog.target(%{"pr_number" => 7, "failed_only" => true}) == {:ok, {:pr, "7"}}
      assert CiLog.target(%{}) == {:error, :missing_ci_log_target}
      assert CiLog.target(%{"run_id" => 1, "job_id" => 2}) == {:error, :ambiguous_ci_log_target}
      assert CiLog.target(%{"run_id" => "1; rm -rf /"}) == {:error, :invalid_ci_log_target}
      assert CiLog.target(%{"run_id" => 0}) == {:error, :invalid_ci_log_target}
      assert CiLog.target(%{"job_id" => 1.5}) == {:error, :invalid_ci_log_target}
    end
  end

  describe "repo_from_url/1" do
    test "reads the repository of a run, job or pull request URL" do
      assert CiLog.repo_from_url(@run_url) == "acme/app"
      assert CiLog.repo_from_url("https://github.com/acme/app/pull/7") == "acme/app"
      assert CiLog.repo_from_url("https://ghe.acme.test/acme/app/actions/runs/1/job/2") == "ghe.acme.test/acme/app"
      assert CiLog.repo_from_url("https://linear.app/acme/issue/TP-1") == nil
      assert CiLog.repo_from_url(nil) == nil
    end
  end

  describe "read/3 of a run" do
    test "reads the failed jobs: failed steps, annotations and the log without gh's columns" do
      assert {:ok, read} = read({:run, "101"})

      assert %{repo: @repo, target: "run 101", workflow: "CI", url: @run_url, failed_only: true, omitted_jobs: 0} = read
      assert [job] = read.jobs
      assert %{job_id: "201", run_id: "101", name: "test", conclusion: "FAILURE", url: @run_url <> "/job/201"} = job
      assert job.failed_steps == ["Verify app bundle"]
      assert job.annotations == ["failure .github:26 Process completed with exit code 1. See the log.", "warning Node 16 is deprecated"]
      assert job.log =~ ~r/\Aline 1\n/
      assert String.ends_with?(job.log, "printf: write error: Broken pipe")
      assert %{log_lines: 5, total_lines: 5, truncated: false} = job

      refute_received {:gh, ["run", "view", "--job", "202" | _rest]}
    end

    test "keeps each job's last lines, each line clipped, and says it cut the log" do
      long = String.duplicate("x", 3_000)
      overrides = %{["run", "view", "--job", "201", "--log-failed", "-R", @repo] => {log(1_000) <> long <> "\n", 0}}

      assert {:ok, %{jobs: [job]}} = read({:run, "101"}, [], overrides)

      assert job.log_lines == CiLog.default_line_limit()
      assert job.total_lines == 1_001
      assert job.truncated
      lines = String.split(job.log, "\n")
      assert length(lines) == 400
      assert hd(lines) == "line 602"
      assert Enum.at(lines, -2) == "printf: write error: Broken pipe"
      assert String.length(List.last(lines)) == CiLog.line_chars()
      assert Enum.all?(lines, &(String.length(&1) <= CiLog.line_chars()))
    end

    test "a smaller line limit keeps fewer lines" do
      assert {:ok, %{line_limit: 2, jobs: [job]}} = read({:run, "101"}, line_limit: 2)
      assert job.log == "line 4\nprintf: write error: Broken pipe"
      assert job.truncated
    end

    test "an empty log or invalid bytes still read" do
      empty = %{["run", "view", "--job", "201", "--log-failed", "-R", @repo] => {"", 0}}
      assert {:ok, %{jobs: [%{log: "", log_lines: 0, total_lines: 0}]}} = read({:run, "101"}, [], empty)

      invalid = %{["run", "view", "--job", "201", "--log-failed", "-R", @repo] => {<<"bad ", 0xFF, " byte">>, 0}}
      assert {:ok, %{jobs: [%{log: "bad ? byte"}]}} = read({:run, "101"}, [], invalid)
    end

    test "reads at most ten jobs and counts the rest" do
      jobs = for n <- 1..12, do: %{"databaseId" => 300 + n, "name" => "shard #{n}", "conclusion" => "failure", "url" => "#{@run_url}/job/#{300 + n}"}

      runner =
        gh(fn
          ["run", "view", "101" | _rest] -> json(run_payload(%{"jobs" => jobs}))
          ["run", "view", "--job", _id, "--log-failed", "-R", @repo] -> {"boom", 0}
          ["api", _annotations] -> {"[]", 0}
        end)

      assert {:ok, read} = CiLog.read(@repo, {:run, "101"}, gh_runner: runner)
      assert length(read.jobs) == CiLog.job_limit()
      assert read.omitted_jobs == 2
      assert hd(read.jobs).annotations == []
    end

    test "with failed_only false reads every job and its whole log" do
      assert {:ok, %{failed_only: false, jobs: [test, lint]}} = read({:run, "101"}, failed_only: false)
      assert test.job_id == "201"
      assert lint.job_id == "202"
      assert lint.log == "ok"
      assert lint.failed_steps == []
    end

    test "refuses a run of another repository" do
      other = %{["run", "view", "101", "-R", @repo, "--json", "databaseId,url,workflowName,jobs"] => json(run_payload(%{"url" => "https://github.com/evil/app/actions/runs/101"}))}
      assert read({:run, "101"}, [], other) == {:error, {:run_not_in_repo, "101", @repo}}

      no_url = %{["run", "view", "101", "-R", @repo, "--json", "databaseId,url,workflowName,jobs"] => json(Map.delete(run_payload(), "url"))}
      assert read({:run, "101"}, [], no_url) == {:error, {:run_not_in_repo, "101", @repo}}
    end

    test "a run with no failed job is an error when failed_only is set" do
      green = %{["run", "view", "101", "-R", @repo, "--json", "databaseId,url,workflowName,jobs"] => json(run_payload(%{"jobs" => [nil]}))}
      assert read({:run, "101"}, [], green) == {:error, {:no_failed_jobs, "101"}}
    end

    test "passes on gh's failures and payloads it cannot read" do
      missing = %{["run", "view", "101", "-R", @repo, "--json", "databaseId,url,workflowName,jobs"] => {"HTTP 404: Not Found", 1}}
      assert {:error, {:gh_failed, _args, 1, "HTTP 404: Not Found"}} = read({:run, "101"}, [], missing)

      garbled = %{["run", "view", "101", "-R", @repo, "--json", "databaseId,url,workflowName,jobs"] => {"[]", 0}}
      assert read({:run, "101"}, [], garbled) == {:error, :invalid_ci_run_payload}

      no_log = %{["run", "view", "--job", "201", "--log-failed", "-R", @repo] => {"log not found", 1}}
      assert {:error, {:ci_log_unavailable, "201", {:gh_failed, _args, 1, "log not found"}}} = read({:run, "101"}, [], no_log)
    end

    test "annotations that cannot be read are left out" do
      overrides = %{["api", "repos/acme/app/check-runs/201/annotations"] => {"HTTP 403", 1}}
      assert {:ok, %{jobs: [%{annotations: []}]}} = read({:run, "101"}, [], overrides)
    end

    test "refuses a repository that is not owner/repo or host/owner/repo" do
      assert CiLog.read("acme", {:run, "101"}, gh_runner: gh(answers())) == {:error, {:invalid_ci_log_repo, "acme"}}
      assert CiLog.read("", {:run, "101"}) == {:error, {:invalid_ci_log_repo, ""}}
    end
  end

  describe "read/3 of a job" do
    test "reads one failed job" do
      assert {:ok, %{target: "job 201", url: url, jobs: [job]}} = read({:job, "201"})
      assert url == @run_url <> "/job/201"
      assert %{job_id: "201", run_id: "101", failed_steps: ["Verify app bundle"]} = job
    end

    test "refuses a job that did not fail when failed_only is set, and reads it when it is not" do
      assert read({:job, "202"}) == {:error, {:job_not_failed, "202", "SUCCESS"}}
      assert {:ok, %{jobs: [%{job_id: "202", log: "ok"}]}} = read({:job, "202"}, failed_only: false)
    end

    test "refuses a job of another repository" do
      other = %{["api", "repos/acme/app/actions/jobs/201"] => json(job_payload("201", "failure", %{"html_url" => "https://github.com/evil/app/actions/runs/9/job/201"}))}
      assert read({:job, "201"}, [], other) == {:error, {:job_not_in_repo, "201", @repo}}

      garbled = %{["api", "repos/acme/app/actions/jobs/201"] => {"not json", 0}}
      assert read({:job, "201"}, [], garbled) == {:error, :invalid_ci_job_payload}
    end

    test "on GitHub Enterprise reads through the host" do
      runner =
        gh(fn
          ["api", "--hostname", "ghe.acme.test", "repos/acme/app/actions/jobs/201"] ->
            json(job_payload("201", "failure", %{"html_url" => "https://ghe.acme.test/acme/app/actions/runs/101/job/201", "run_id" => "101"}))

          ["api", "--hostname", "ghe.acme.test", "repos/acme/app/check-runs/201/annotations"] ->
            {"[]", 0}

          ["run", "view", "--job", "201", "--log-failed", "-R", "ghe.acme.test/acme/app"] ->
            {"boom", 0}
        end)

      assert {:ok, %{jobs: [%{log: "boom", run_id: "101"}]}} = CiLog.read("ghe.acme.test/acme/app", {:job, "201"}, gh_runner: runner)
    end
  end

  describe "read/3 of a pull request" do
    defp pr_answer(checks) do
      %{
        [
          "pr",
          "view",
          "https://github.com/acme/app/pull/7",
          "--json",
          "id,number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup"
        ] => json(%{"url" => "https://github.com/acme/app/pull/7", "headRefOid" => "abc", "statusCheckRollup" => checks})
      }
    end

    defp check(name, conclusion, url), do: %{"__typename" => "CheckRun", "name" => name, "status" => "COMPLETED", "conclusion" => conclusion, "detailsUrl" => url}

    test "reads the jobs of its failed GitHub Actions checks in this repository" do
      checks = [
        check("test", "FAILURE", @run_url <> "/job/201"),
        check("lint", "SUCCESS", @run_url <> "/job/202"),
        check("other repo", "FAILURE", "https://github.com/evil/app/actions/runs/9/job/9"),
        check("an app's check", "FAILURE", "https://ci.example.test/build/1"),
        %{"__typename" => "StatusContext", "context" => "deploy", "state" => "FAILURE"}
      ]

      assert {:ok, %{target: "pr 7", url: "https://github.com/acme/app/pull/7", jobs: [job], omitted_jobs: 0}} = read({:pr, "7"}, [], pr_answer(checks))
      assert job.job_id == "201"
    end

    test "with failed_only false reads every job check" do
      checks = [check("test", "FAILURE", @run_url <> "/job/201"), check("lint", "SUCCESS", @run_url <> "/job/202")]
      assert {:ok, %{jobs: [%{job_id: "201"}, %{job_id: "202"}]}} = read({:pr, "7"}, [failed_only: false], pr_answer(checks))
    end

    test "a pull request with no failed job is an error" do
      checks = [check("lint", "FAILURE", "https://ci.example.test/build/1")]
      assert read({:pr, "7"}, [], pr_answer(checks)) == {:error, {:no_failed_jobs, {:pr, "7"}}}
    end

    test "reads at most ten jobs and counts the rest" do
      checks = for n <- 1..11, do: check("shard #{n}", "FAILURE", "#{@run_url}/job/#{300 + n}")

      runner =
        gh(fn
          ["pr", "view" | _rest] = args -> pr_answer(checks) |> Map.fetch!(args)
          ["api", "repos/acme/app/actions/jobs/" <> id] -> json(job_payload(id, "failure"))
          ["api", _annotations] -> {"[]", 0}
          ["run", "view", "--job", _id, "--log-failed", "-R", @repo] -> {"boom", 0}
        end)

      assert {:ok, read} = CiLog.read(@repo, {:pr, "7"}, gh_runner: runner)
      assert length(read.jobs) == 10
      assert read.omitted_jobs == 1
      refute_received {:gh, ["api", "repos/acme/app/actions/jobs/311"]}
    end

    test "a job that cannot be read fails the read" do
      checks = [check("test", "FAILURE", @run_url <> "/job/201")]
      overrides = Map.put(pr_answer(checks), ["api", "repos/acme/app/actions/jobs/201"], {"HTTP 404", 1})
      assert {:error, {:gh_failed, _args, 1, "HTTP 404"}} = read({:pr, "7"}, [], overrides)
    end

    test "a pull request that cannot be read fails the read" do
      overrides = %{
        [
          "pr",
          "view",
          "https://github.com/acme/app/pull/7",
          "--json",
          "id,number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup"
        ] => {"no pull requests found", 1}
      }

      assert {:error, _reason} = read({:pr, "7"}, [], overrides)
    end
  end

  test "failed?/1 reads any failed conclusion, in any case" do
    assert CiLog.failed?("failure")
    assert CiLog.failed?("TIMED_OUT")
    refute CiLog.failed?("success")
    refute CiLog.failed?(nil)
  end
end
