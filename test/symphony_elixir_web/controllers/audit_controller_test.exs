defmodule SymphonyElixirWeb.AuditControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.AuditLog

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    audit_dir = Path.join(System.tmp_dir!(), "symphony-audit-api-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

    on_exit(fn ->
      if previous_audit_dir,
        do: Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir),
        else: Application.delete_env(:symphony_elixir, :audit_log_dir)

      File.rm_rf(audit_dir)
    end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    {:ok, audit_dir: audit_dir}
  end

  test "GET /api/v1/audit/verify says each day of the range verified, or names its first broken record", %{audit_dir: dir} do
    record_day!(dir, ~D[2026-05-06], 2)
    record_day!(dir, ~D[2026-05-07], 3)

    path = Path.join(dir, "2026-05-07.ndjson")
    [first, second, third] = path |> File.read!() |> String.split("\n", trim: true)
    tampered = second |> Jason.decode!() |> Map.put("move", "rework") |> Jason.encode!()
    File.write!(path, Enum.join([first, tampered, third], "\n") <> "\n")
    %{"record_hash" => broken_hash} = Jason.decode!(tampered)

    body = json_response(get(build_conn(), "/api/v1/audit/verify?from=2026-05-06&to=2026-05-08"), 200)

    assert %{"from" => "2026-05-06", "to" => "2026-05-08", "days" => [verified, broken, empty]} = body
    assert verified == %{"date" => "2026-05-06", "verified" => true, "broken" => nil}
    assert empty == %{"date" => "2026-05-08", "verified" => true, "broken" => nil}

    assert %{
             "date" => "2026-05-07",
             "verified" => false,
             "broken" => %{
               "line" => 2,
               "record_hash" => ^broken_hash,
               "reason" => "chain_break",
               "record" => %{"issue_identifier" => "AUD-2", "move" => "rework", "event_type" => "director_move"}
             }
           } = broken
  end

  test "GET /api/v1/audit/verify reports a line that isn't a record", %{audit_dir: dir} do
    record_day!(dir, ~D[2026-05-07], 1)
    File.write!(Path.join(dir, "2026-05-07.ndjson"), "not json\n", [:append])

    assert %{"days" => [%{"verified" => false, "broken" => broken}]} =
             json_response(get(build_conn(), "/api/v1/audit/verify?date=2026-05-07&to=2026-05-09"), 200)

    assert broken == %{"line" => 2, "record_hash" => nil, "reason" => "invalid_record", "record" => nil}
  end

  test "GET /api/v1/audit/verify reads today by default and refuses a bad range" do
    today = Date.utc_today() |> Date.to_iso8601()

    assert %{"from" => ^today, "to" => ^today, "days" => [%{"date" => ^today, "verified" => true}]} =
             json_response(get(build_conn(), "/api/v1/audit/verify"), 200)

    for query <- ["date=nope", "from=2026-05-07&to=2026-05-06", "from=2026-01-01&to=2026-02-01", "date[]=2026-05-07"] do
      assert %{"error" => %{"code" => "invalid_audit_filter"}} =
               json_response(get(build_conn(), "/api/v1/audit/verify?" <> query), 400)
    end

    assert json_response(post(build_conn(), "/api/v1/audit/verify", %{}), 405)["error"]["code"] == "method_not_allowed"
  end

  test "GET /api/v1/audit?last=N serves the newest N matching records and says when it dropped older ones", %{audit_dir: dir} do
    record_day!(dir, ~D[2026-05-07], 5)

    conn = get(build_conn(), "/api/v1/audit?from=2026-05-07&last=2")
    assert identifiers(conn) == ["AUD-4", "AUD-5"]
    assert Plug.Conn.get_resp_header(conn, "x-audit-truncated") == ["true"]

    all = get(build_conn(), "/api/v1/audit?from=2026-05-07&last=10")
    assert identifiers(all) == ["AUD-1", "AUD-2", "AUD-3", "AUD-4", "AUD-5"]
    assert Plug.Conn.get_resp_header(all, "x-audit-truncated") == []

    for query <- ["last=0", "last=bad", "last[]=2", "last=2&limit=2", "last=2&cursor=2026-05-07:abc"] do
      assert json_response(get(build_conn(), "/api/v1/audit?from=2026-05-07&" <> query), 400)["error"]["code"] ==
               "invalid_audit_filter"
    end
  end

  test "AuditLog.record_at reads the redacted record on a line, nil otherwise", %{audit_dir: dir} do
    record_day!(dir, ~D[2026-05-07], 2)

    assert %{"issue_identifier" => "AUD-2"} = AuditLog.record_at("2026-05-07", 2)
    assert AuditLog.record_at(~D[2026-05-07], 3) == nil
    assert AuditLog.record_at("nope", 1) == nil
    assert AuditLog.record_at(~D[2026-05-07], 1, dir: Path.join(dir, "missing")) == nil
  end

  defp record_day!(dir, date, count) do
    for n <- 1..count do
      assert :ok =
               AuditLog.record(
                 %{
                   event_type: "director_move",
                   move: "approve_pr",
                   repo_key: "web",
                   issue_id: "issue-#{n}",
                   issue_identifier: "AUD-#{n}",
                   timestamp: DateTime.new!(date, Time.new!(10, n, 0))
                 },
                 dir: dir
               )
    end
  end

  defp identifiers(conn) do
    conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&(&1 |> Jason.decode!() |> Map.fetch!("issue_identifier")))
  end
end
