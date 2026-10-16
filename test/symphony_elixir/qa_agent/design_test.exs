defmodule SymphonyElixir.QaAgent.DesignTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.QaAgent.Design

  @upload "https://uploads.linear.app/org/asset"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "lin_api_test")
    dir = Path.join(System.tmp_dir!(), "qa-design-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, settings: Config.settings!()}
  end

  test "downloads the ticket's and the parent's HTML screens and images, newest per title", %{dir: dir, settings: settings} do
    issue = %{
      "identifier" => "TP-900",
      "attachments" => %{
        "nodes" => [
          %{"title" => "Before and after.png", "url" => "#{@upload}/shot", "createdAt" => "2026-10-02T00:00:00Z"},
          %{"title" => "PR #12", "url" => "https://github.com/acme/app/pull/12", "createdAt" => "2026-10-02T00:00:00Z"}
        ]
      },
      "parent" => %{
        "identifier" => "TP-899",
        "attachments" => %{
          "nodes" => [
            %{"title" => "screens.html", "url" => "#{@upload}/old", "createdAt" => "2026-10-01T00:00:00Z"},
            %{"title" => "screens.html", "url" => "#{@upload}/new", "createdAt" => "2026-10-03T00:00:00Z"},
            %{"title" => "Flow diagram", "url" => "#{@upload}/flow.svg", "createdAt" => "2026-10-01T00:00:00Z"},
            %{"title" => "notes.txt", "url" => "#{@upload}/notes", "createdAt" => "2026-10-01T00:00:00Z"},
            %{"title" => "mock.png", "url" => "https://evil.example/mock.png", "createdAt" => "2026-10-01T00:00:00Z"},
            %{"title" => nil, "url" => "#{@upload}/untitled.png"}
          ]
        }
      }
    }

    recipient = self()

    linear_client = fn query, variables, _opts ->
      send(recipient, {:linear_query, query, variables})
      {:ok, %{"data" => %{"issue" => issue}}}
    end

    download_client = fn url, opts ->
      send(recipient, {:download, url, opts[:headers]})
      {:ok, %{status: 200, body: "body of #{url}"}}
    end

    files = Design.fetch(issue(), dir, settings, linear_client: linear_client, download_client: download_client)

    assert_received {:linear_query, "query SymphonyQaDesignAttachments" <> _rest, %{id: "issue-qa", first: 50}}

    assert [
             %{issue: "TP-900", title: "Before and after.png", path: shot},
             %{issue: "TP-899", title: "screens.html", path: screens},
             %{issue: "TP-899", title: "Flow diagram", path: flow}
           ] = files

    assert shot == Path.join([dir, "design", "TP-900-Before_and_after.png"])
    assert screens == Path.join([dir, "design", "TP-899-screens.html"])
    assert flow == Path.join([dir, "design", "TP-899-Flow_diagram.svg"])
    assert File.read!(screens) == "body of #{@upload}/new"
    assert_received {:download, "https://uploads.linear.app/org/asset/new", [{"authorization", "lin_api_test"}]}
    refute_received {:download, "https://uploads.linear.app/org/asset/old", _headers}
    refute_received {:download, "https://evil.example/mock.png", _headers}
  end

  test "skips files it cannot download and survives a failed read", %{dir: dir, settings: settings} do
    nodes = for title <- ["a.png", "b.png", "c.png", "d.png"], do: %{"title" => title, "url" => "#{@upload}/#{title}"}

    answer = %{"identifier" => "TP-900", "attachments" => %{"nodes" => nodes}, "parent" => nil}
    linear_client = fn _query, _variables, _opts -> {:ok, %{"data" => %{"issue" => answer}}} end

    download_client = fn url, _opts ->
      cond do
        String.ends_with?(url, "a.png") -> {:ok, %{status: 200, body: "ok"}}
        String.ends_with?(url, "b.png") -> {:ok, %{status: 403, body: "denied"}}
        String.ends_with?(url, "c.png") -> {:error, :timeout}
        String.ends_with?(url, "d.png") -> {:ok, %{status: 200, body: :binary.copy("x", 20 * 1024 * 1024 + 1)}}
      end
    end

    log =
      capture_log(fn ->
        assert [%{title: "a.png"}] = Design.fetch(issue(), dir, settings, linear_client: linear_client, download_client: download_client)
      end)

    assert log =~ ~s(QA could not download the design file "b.png" of TP-900: {:http_status, 403})
    assert log =~ ":timeout"
    assert log =~ "{:too_large, 20971521}"

    for answer <- [{:error, :linear_down}, {:ok, %{"data" => %{"issue" => nil}}}] do
      log = capture_log(fn -> assert [] = Design.fetch(issue(), dir, settings, linear_client: fn _q, _v, _o -> answer end) end)
      assert log =~ "QA could not read the design attachments for TP-900"
    end
  end

  test "names a file without a usable title and sends no key when none is set", %{dir: dir, settings: settings} do
    nodes = [%{"title" => "???", "url" => "#{@upload}/x.webp"}]
    linear_client = fn _query, _variables, _opts -> {:ok, %{"data" => %{"issue" => %{"identifier" => "TP-900", "attachments" => %{"nodes" => nodes}}}}} end
    recipient = self()

    download_client = fn _url, opts ->
      send(recipient, {:headers, opts[:headers]})
      {:ok, %{status: 200, body: "img"}}
    end

    settings = put_in(settings.tracker.api_key, nil)

    assert [%{path: path}] = Design.fetch(issue(), dir, settings, linear_client: linear_client, download_client: download_client)
    assert Path.basename(path) == "TP-900-file.webp"
    assert_received {:headers, []}
  end

  test "fetches nothing on other trackers or without an issue id", %{dir: dir, settings: settings} do
    no_call = fn _query, _variables, _opts -> flunk("Linear must not be called") end

    assert [] = Design.fetch(issue(), dir, put_in(settings.tracker.kind, "memory"), linear_client: no_call)
    assert [] = Design.fetch(%{issue() | id: nil}, dir, settings, linear_client: no_call)
  end

  defp issue, do: %Issue{id: "issue-qa", identifier: "TP-900", title: "Add a check command"}
end
