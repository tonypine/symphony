defmodule SymphonyElixir.HumanActions.WaitingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Request, Waiting}

  defp node(identifier, attrs) do
    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Title of " <> identifier,
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "state" => %{"name" => "Plan Review"},
        "labels" => %{"nodes" => [%{"name" => "plan"}]},
        "comments" => %{"nodes" => []},
        "history" => %{"nodes" => []}
      },
      attrs
    )
  end

  defp labels(names), do: %{"nodes" => Enum.map(names, &%{"name" => &1})}
  defp comments(comments), do: %{"nodes" => comments}
  defp history(entries), do: %{"nodes" => entries}
  defp moved(to, at), do: %{"createdAt" => at, "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => to}}

  defp brief(headline_line, created_at \\ "2026-10-01T10:00:00Z") do
    body = """
    ## Review brief

    #{headline_line}

    - https://github.com/acme/repo/pull/1

    **Decisions needed:**

    None.
    """

    %{"id" => "brief", "body" => body, "createdAt" => created_at}
  end

  defp request_comment(created_at) do
    options = [%{label: "Add it", effect: "Releases sign again.", recommended: true}, %{label: "Drop it", effect: "Unsigned."}]

    body =
      Request.render_hold(
        %{title: "Add the signing secret", question: "Add it?", why: "Release fails.", unblocks: "Release", est_minutes: 5, options: options},
        "Code Review"
      )

    %{"id" => "request", "body" => body, "createdAt" => created_at}
  end

  defp entries(nodes), do: Waiting.entries(nodes, %Schema{})

  test "lists a plan in Plan Review, with the brief's headline and when it entered the state" do
    plan =
      node("TP-2", %{
        "labels" => labels(["Plan"]),
        "comments" => comments([brief("**What to review:**\n\n- The split into four sub-tickets")]),
        "history" => history([moved("Todo", "2026-10-01T07:00:00Z"), moved("Plan Review", "2026-10-01T08:00:00Z")])
      })

    assert [
             %{
               issue_id: "id-TP-2",
               identifier: "TP-2",
               title: "Title of TP-2",
               url: "https://linear.app/acme/issue/TP-2",
               state: "Plan Review",
               kind: :plan,
               waiting_since: ~U[2026-10-01 08:00:00Z],
               headline: "The split into four sub-tickets"
             }
           ] = entries([plan])
  end

  test "a ticket that is not a plan waits on nobody in Plan Review, and neither does one in a retired state" do
    pr = node("TP-1", %{"labels" => labels([]), "comments" => comments([brief("**What to review:** The retry fix in the poller")])})
    verification = node("TP-3", %{"title" => "Final verification: Ship it", "labels" => labels([])})
    in_review = node("TP-13", %{"state" => %{"name" => "In Review"}})

    assert entries([pr, verification, in_review]) == []
  end

  test "an open request makes the issue an action, waiting since the request when its history has no move" do
    action = node("TP-4", %{"state" => %{"name" => "Code Review"}, "labels" => labels([]), "comments" => comments([request_comment("2026-10-02T07:00:00Z")])})

    assert [%{identifier: "TP-4", kind: :action, waiting_since: ~U[2026-10-02 07:00:00Z], headline: nil}] = entries([action])
  end

  test "an open request newer than the move into the state waits since the request" do
    held =
      node("TP-11", %{
        "state" => %{"name" => "In Progress"},
        "history" => history([moved("In Progress", "2026-09-01T08:00:00Z")]),
        "comments" => comments([request_comment("2026-10-02T07:00:00Z")])
      })

    assert [%{identifier: "TP-11", kind: :action, waiting_since: ~U[2026-10-02 07:00:00Z]}] = entries([held])
  end

  test "a plan with no request waits since its latest move into Plan Review" do
    plan = node("TP-12", %{"history" => history([moved("Plan Review", "2026-10-01T09:00:00Z"), moved("Plan Review", "2026-10-01T11:00:00Z")])})

    assert [%{identifier: "TP-12", kind: :plan, waiting_since: ~U[2026-10-01 11:00:00Z]}] = entries([plan])
  end

  test "skips issues outside Plan Review with no open request, and nodes without an id" do
    assert entries([node("TP-5", %{"state" => %{"name" => "Todo"}}), node("TP-6", %{"state" => nil}), %{"identifier" => "TP-7"}]) == []
  end

  test "an issue with no state change or request into its state waits since nil" do
    stray =
      node("TP-8", %{
        "history" =>
          history([
            moved("Todo", "2026-10-01T08:00:00Z"),
            %{"createdAt" => "soon", "toState" => %{"name" => "Plan Review"}},
            %{"createdAt" => nil, "toState" => %{"name" => "Plan Review"}},
            %{"createdAt" => "2026-10-01T08:00:00Z", "toState" => %{"name" => nil}}
          ])
      })

    assert [%{waiting_since: nil}] = entries([stray])

    # An issue read without a state waits since its request.
    stateless = node("TP-10", %{"state" => nil, "comments" => comments([request_comment("2026-10-02T07:00:00Z")])})
    assert [%{kind: :action, state: nil, waiting_since: ~U[2026-10-02 07:00:00Z]}] = entries([stateless])
  end

  test "reads the headline of the latest brief, ignoring other comments" do
    old = brief("**What to review:** Old headline", "2026-10-01T10:00:00Z")
    new = brief("**What to review:** New headline", "2026-10-03T10:00:00Z")
    workpad = %{"id" => "workpad", "body" => "## Symphony Workpad\n\n**What to review:** not a brief", "createdAt" => "2026-10-04T10:00:00Z"}

    assert [%{headline: "New headline"}] = entries([node("TP-9", %{"comments" => comments([new, old, workpad, %{"id" => "x"}])})])
  end

  test "brief_headline/1 reads the line after the label, else the first line under it" do
    assert Waiting.brief_headline("## Review brief\n\n**What to review:**   the  plan  ") == "the plan"
    assert Waiting.brief_headline("## Review brief\r\n**What to review:**\r\n\r\n1. First item\r\n2. Second") == "First item"
    assert Waiting.brief_headline("## Review brief\n\n**What to review:**\n") == nil
    assert Waiting.brief_headline("## Review brief\n\nNothing to review here.") == nil
    assert Waiting.brief_headline(nil) == nil

    long = String.duplicate("a", 250)
    assert Waiting.brief_headline("**What to review:** " <> long) == String.duplicate("a", 199) <> "…"
  end
end
