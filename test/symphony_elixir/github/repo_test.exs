defmodule SymphonyElixir.GitHub.RepoTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Repo

  test "extracts owner and repo from supported GitHub origin URLs" do
    assert Repo.from_url("git@github.com:acme/symphony.git") == "acme/symphony"
    assert Repo.from_url("https://github.com/acme/symphony.git") == "acme/symphony"
    assert Repo.from_url("ssh://git@github.com/acme/symphony/") == "acme/symphony"
  end

  test "extracts owner and repo from configured enterprise origin URLs" do
    opts = [github_enterprise_hosts: ["github.a8c.com"]]

    assert Repo.from_url("git@github.a8c.com:Automattic/symphony.git", opts) == "Automattic/symphony"
    assert Repo.from_url("https://github.a8c.com/Automattic/symphony.git", opts) == "Automattic/symphony"
    assert Repo.from_url("ssh://git@github.a8c.com/Automattic/symphony/", opts) == "Automattic/symphony"
  end

  test "an enterprise host cannot be told from any other when the settings do not load" do
    File.write!(Workflow.symphony_file_path(), "issues:\n  provider: memory\n")
    assert {:error, _reason} = Config.settings()

    assert Repo.from_url("git@github.a8c.com:Automattic/symphony.git") == nil
    assert Repo.from_url("git@github.com:acme/symphony.git") == "acme/symphony"
  end

  test "formats GitHub CLI repo targets for public and enterprise origins" do
    opts = [github_enterprise_hosts: ["github.a8c.com"]]

    assert Repo.gh_repo_from_url("git@github.com:acme/symphony.git") == "acme/symphony"
    assert Repo.gh_repo_from_url("git@github.a8c.com:Automattic/symphony.git", opts) == "github.a8c.com/Automattic/symphony"
  end

  test "one-arity helpers use configured enterprise hosts" do
    write_workflow_file!(Workflow.workflow_file_path(), github: %{enterprise_hosts: ["github.a8c.com"]})

    assert Repo.from_url("https://github.a8c.com/Automattic/symphony.git") == "Automattic/symphony"
    assert Repo.gh_repo_from_url("https://github.a8c.com/Automattic/symphony.git") == "github.a8c.com/Automattic/symphony"
  end

  test "rejects missing malformed and non-GitHub URLs" do
    assert Repo.from_url(nil) == nil
    assert Repo.gh_repo_from_url(nil) == nil
    assert Repo.from_url("git@github.com-acme/symphony.git") == nil
    assert Repo.from_url("https://example.com/acme/symphony.git") == nil
    assert Repo.from_url("https://github.a8c.com/Automattic/symphony.git") == nil
    assert Repo.gh_repo_from_url("https://github.a8c.com/Automattic/symphony.git") == nil
    assert Repo.from_url("https://github.evil.test/acme/symphony.git", github_enterprise_hosts: ["github.a8c.com"]) == nil
    assert Repo.from_url("not a url") == nil
  end

  test "compares normalized repo targets" do
    assert Repo.same?(" Acme/Symphony.git ", "acme/symphony/")
    refute Repo.same?("acme/symphony", "other/symphony")
    refute Repo.same?(nil, "acme/symphony")
  end
end
