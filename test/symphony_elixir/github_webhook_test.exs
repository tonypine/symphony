defmodule SymphonyElixir.GitHubWebhookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.GitHub.Webhooks
  alias SymphonyElixir.GitHub.Webhook
  alias SymphonyElixir.{Paths, Secret}

  @events ["check_suite", "check_run", "workflow_run", "pull_request", "push", "release"]
  @repository %{"full_name" => "example/repo", "html_url" => "https://github.com/example/repo"}

  describe "config" do
    test "webhooks are off by default, listen to every CI, push and release event, and poll every 5 minutes while healthy" do
      webhooks = Config.settings!().github.webhooks
      assert %Webhooks{enabled: false, relay: "smee", secret: nil, events: @events} = webhooks
      assert %Webhooks{fallback_poll_interval_ms: 300_000, silence_alert_minutes: 10} = webhooks
    end

    test "the safety-net interval and the silence alert are read, and must be positive" do
      webhooks = %{fallback_poll_interval_ms: 120_000, silence_alert_minutes: 30}
      write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: webhooks})
      assert %Webhooks{fallback_poll_interval_ms: 120_000, silence_alert_minutes: 30} = Webhook.settings()

      for webhooks <- [%{fallback_poll_interval_ms: 0}, %{silence_alert_minutes: 0}] do
        write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: webhooks})
        assert {:error, _reason} = Config.settings()
      end
    end

    test "the secret resolves from the environment and never shows in inspect" do
      System.put_env("SYMPHONY_TEST_WEBHOOK_SECRET", "s3cret")
      on_exit(fn -> System.delete_env("SYMPHONY_TEST_WEBHOOK_SECRET") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        github: %{webhooks: %{enabled: true, relay: "cloudflare_tunnel", secret: "$SYMPHONY_TEST_WEBHOOK_SECRET", events: ["check_suite"]}}
      )

      webhooks = Config.settings!().github.webhooks

      assert %Webhooks{enabled: true, relay: "cloudflare_tunnel", events: ["check_suite"]} = webhooks
      assert Secret.unwrap(webhooks.secret) == "s3cret"
      refute inspect(webhooks) =~ "s3cret"
      assert Webhook.settings() == webhooks
    end

    test "an unknown relay or event is a config error" do
      write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: %{relay: "ngrok"}})
      assert {:error, _reason} = Config.settings()

      write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: %{events: ["issues"]}})
      assert {:error, _reason} = Config.settings()
    end

    test "settings fall back to webhooks off when the config can't be read" do
      write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: %{relay: "ngrok"}})

      assert %Webhooks{enabled: false} = Webhook.settings()
    end
  end

  describe "secret/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "symphony-webhook-secret-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Paths.set_state_root(root)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :state_root_override)
        File.rm_rf(root)
      end)

      :ok
    end

    test "prefers the configured secret" do
      File.write!(Paths.github_webhook_secret_file(), "from-file")

      assert Secret.unwrap(Webhook.secret(%Webhooks{secret: Secret.wrap("from-config")})) == "from-config"
    end

    test "falls back to the state folder file, trimmed" do
      File.write!(Paths.github_webhook_secret_file(), "from-file\n")

      assert Secret.unwrap(Webhook.secret(%Webhooks{})) == "from-file"
    end

    test "is nil when the file is missing or blank" do
      assert Webhook.secret(%Webhooks{}) == nil

      File.write!(Paths.github_webhook_secret_file(), "  \n")
      assert Webhook.secret(%Webhooks{}) == nil
    end
  end

  describe "verify/3" do
    test "accepts the HMAC-SHA256 of the raw body, in either case" do
      secret = Secret.wrap("s3cret")
      body = ~s({"zen":"Keep it logically awesome."})

      assert Webhook.verify(body, sign(body, "s3cret"), secret) == :ok
      assert Webhook.verify(body, String.upcase(sign(body, "s3cret")) |> String.replace("SHA256=", "sha256="), secret) == :ok
    end

    test "rejects a wrong, malformed or missing signature, and any delivery without a secret" do
      secret = Secret.wrap("s3cret")
      body = ~s({"action":"completed"})

      assert Webhook.verify(body, sign(body, "other"), secret) == {:error, :bad_signature}
      assert Webhook.verify(body <> " ", sign(body, "s3cret"), secret) == {:error, :bad_signature}
      assert Webhook.verify(body, "sha1=abc", secret) == {:error, :bad_signature}
      assert Webhook.verify(body, nil, secret) == {:error, :missing_signature}
      assert Webhook.verify(body, "", secret) == {:error, :missing_signature}
      assert Webhook.verify(body, sign(body, "s3cret"), nil) == {:error, :no_secret}
    end
  end

  describe "parse/3" do
    test "a completed check suite, check run or workflow run names its head, conclusion and PRs" do
      for event <- ["check_suite", "check_run", "workflow_run"] do
        payload = %{
          "action" => "completed",
          "repository" => @repository,
          event => %{
            "head_sha" => "abc123",
            "conclusion" => "failure",
            "completed_at" => "2026-05-06T09:00:00Z",
            "pull_requests" => [%{"number" => 7}, %{"number" => "bad"}, %{}]
          }
        }

        assert Webhook.parse(event, payload, @events) ==
                 {:ci,
                  %{
                    event: event,
                    action: "completed",
                    head_sha: "abc123",
                    conclusion: "failure",
                    completed_at: ~U[2026-05-06 09:00:00Z],
                    pr_urls: ["https://github.com/example/repo/pull/7"],
                    merged: false,
                    base_ref: nil
                  }}
      end
    end

    test "a completed check falls back to its updated_at, and reads a missing or unparseable time as nil" do
      for {subject, expected} <- [
            {%{"head_sha" => "abc", "updated_at" => "2026-05-06T10:00:00Z"}, ~U[2026-05-06 10:00:00Z]},
            {%{"head_sha" => "abc"}, nil},
            {%{"head_sha" => "abc", "completed_at" => "not a time"}, nil}
          ] do
        assert {:ci, %{completed_at: ^expected}} = Webhook.parse("check_run", %{"action" => "completed", "check_run" => subject}, @events)
      end

      assert {:ci, %{conclusion: nil}} =
               Webhook.parse("check_run", %{"action" => "completed", "check_run" => %{"head_sha" => "abc", "conclusion" => "  "}}, @events)
    end

    test "a check event with no PR list still names its head" do
      payload = %{"action" => "completed", "check_suite" => %{"head_sha" => "abc123"}}

      assert {:ci, %{head_sha: "abc123", pr_urls: []}} = Webhook.parse("check_suite", payload, @events)
    end

    test "a pull request that moved its head, closed or reopened names its URL" do
      for action <- ["synchronize", "closed", "reopened"] do
        payload = %{
          "action" => action,
          "repository" => @repository,
          "pull_request" => %{"html_url" => "https://github.com/example/repo/pull/7", "head" => %{"sha" => "def456"}, "base" => %{"ref" => "main"}}
        }

        assert Webhook.parse("pull_request", payload, @events) ==
                 {:ci,
                  %{
                    event: "pull_request",
                    action: action,
                    head_sha: "def456",
                    conclusion: nil,
                    completed_at: nil,
                    pr_urls: ["https://github.com/example/repo/pull/7"],
                    merged: false,
                    base_ref: "main"
                  }}
      end
    end

    test "a pull request closed by merging says so, since its base branch moved" do
      pull_request = %{"html_url" => "https://github.com/example/repo/pull/7", "head" => %{"sha" => "def456"}, "merged" => true}

      assert {:ci, %{action: "closed", merged: true}} =
               Webhook.parse("pull_request", %{"action" => "closed", "repository" => @repository, "pull_request" => pull_request}, @events)

      assert {:ci, %{action: "reopened", merged: false}} =
               Webhook.parse("pull_request", %{"action" => "reopened", "repository" => @repository, "pull_request" => pull_request}, @events)

      assert Webhook.parse("pull_request", %{"action" => "closed", "pull_request" => %{"merged" => true}}, @events) == :ignored
    end

    test "a push to a branch names the repository, the branch and its new head; a tag or a deleted branch is ignored" do
      payload = %{"ref" => "refs/heads/main", "after" => "abc123", "repository" => @repository}

      assert Webhook.parse("push", payload, @events) == {:push, %{repo_url: "https://github.com/example/repo", ref: "main", head_sha: "abc123"}}
      assert Webhook.parse("push", %{payload | "after" => ""}, @events) == {:push, %{repo_url: "https://github.com/example/repo", ref: "main", head_sha: nil}}
      assert Webhook.parse("push", %{payload | "ref" => "refs/tags/v1"}, @events) == :ignored
      assert Webhook.parse("push", Map.put(payload, "deleted", true), @events) == :ignored
      assert Webhook.parse("push", payload, ["check_suite"]) == :ignored
    end

    test "a published release names its repository, tag and publish time; a draft or another action is ignored" do
      release = %{"tag_name" => "v1.2.0", "published_at" => "2026-10-16T08:00:00Z", "prerelease" => false}
      payload = %{"action" => "published", "release" => release, "repository" => %{"full_name" => "tonypine/symphony"}}

      assert Webhook.parse("release", payload, @events) ==
               {:release, %{repo: "tonypine/symphony", tag: "v1.2.0", published_at: ~U[2026-10-16 08:00:00Z], prerelease: false}}

      assert {:release, %{prerelease: true, published_at: nil}} =
               Webhook.parse("release", put_in(payload, ["release"], %{release | "prerelease" => true, "published_at" => "soon"}), @events)

      assert Webhook.parse("release", put_in(payload, ["release", "draft"], true), @events) == :ignored
      assert Webhook.parse("release", %{payload | "action" => "created"}, @events) == :ignored
      assert Webhook.parse("release", put_in(payload, ["release", "tag_name"], ""), @events) == :ignored
    end

    test "pings, other actions, other events and events left out of the config" do
      assert Webhook.parse("ping", %{"zen" => "hi"}, []) == :ping
      assert Webhook.parse("check_suite", %{"action" => "requested", "check_suite" => %{"head_sha" => "abc"}}, @events) == :ignored
      assert Webhook.parse("check_suite", %{"action" => "completed"}, @events) == :ignored
      assert Webhook.parse("check_suite", %{"action" => "completed", "check_suite" => %{"pull_requests" => []}}, @events) == :ignored
      assert Webhook.parse("pull_request", %{"action" => "labeled", "pull_request" => %{}}, @events) == :ignored
      assert Webhook.parse("push", %{"after" => "abc"}, @events) == :ignored
      assert Webhook.parse("check_run", %{"action" => "completed", "check_run" => %{"head_sha" => "abc"}}, ["check_suite"]) == :ignored
      assert Webhook.parse(nil, %{}, @events) == :ignored
      assert Webhook.parse("check_suite", nil, @events) == :ignored
    end
  end

  test "repository_url/1 reads the repository a payload names" do
    assert Webhook.repository_url(%{"repository" => @repository}) == "https://github.com/example/repo"
    assert Webhook.repository_url(%{"repository" => %{"html_url" => ""}}) == nil
    assert Webhook.repository_url(nil) == nil
  end

  defp sign(body, secret) do
    "sha256=" <> (:hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower))
  end
end
