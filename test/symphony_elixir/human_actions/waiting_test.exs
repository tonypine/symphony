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
        "state" => %{"name" => "In Review"},
        "labels" => %{"nodes" => []},
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
      Request.render(
        %{title: "Add the signing secret", question: "Add it?", why: "Release fails.", unblocks: "Release", est_minutes: 5, options: options},
        "Human Review"
      )

    %{"id" => "request", "body" => body, "createdAt" => created_at}
  end

  defp entries(nodes), do: Waiting.entries(nodes, %Schema{})

  test "lists PRs and a plan in a review state, with the brief's headline and when each entered the state" do
    pr =
      node("TP-1", %{
        "state" => %{"name" => "Human Review"},
        "comments" => comments([brief("**What to review:** The retry fix in the poller")]),
        "history" => history([moved("In Review", "2026-10-01T09:00:00Z"), moved("Human Review", "2026-10-01T11:00:00Z")])
      })

    plan =
      node("TP-2", %{
        "labels" => labels(["Plan"]),
        "comments" => comments([brief("**What to review:**\n\n- The split into four sub-tickets")]),
        "history" => history([moved("In Review", "2026-10-01T08:00:00Z")])
      })

    bare = node("TP-3", %{})

    assert [
             %{
               issue_id: "id-TP-1",
               identifier: "TP-1",
               title: "Title of TP-1",
               url: "https://linear.app/acme/issue/TP-1",
               state: "Human Review",
               kind: :pr,
               waiting_since: ~U[2026-10-01 11:00:00Z],
               headline: "The retry fix in the poller"
             },
             %{identifier: "TP-2", kind: :plan, waiting_since: ~U[2026-10-01 08:00:00Z], headline: "The split into four sub-tickets"},
             %{identifier: "TP-3", kind: :pr, waiting_since: nil, headline: nil}
           ] = entries([pr, plan, bare])
  end

  test "a designed repo's plan parent waiting in Plan Review is a plan, and nothing else is listed for that state" do
    assert {:ok, designed} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"})

    plan =
      node("TP-20", %{
        "state" => %{"name" => "Plan Review"},
        "labels" => labels(["breakdown"]),
        "history" => history([moved("Plan Review", "2026-10-01T08:00:00Z")])
      })

    not_a_plan = node("TP-21", %{"state" => %{"name" => "Plan Review"}})
    approved = node("TP-22", %{"state" => %{"name" => "Waiting on sub-tickets"}, "labels" => labels(["plan"])})

    assert [%{identifier: "TP-20", kind: :plan, state: "Plan Review", waiting_since: ~U[2026-10-01 08:00:00Z]}] =
             Waiting.entries([plan, not_a_plan, approved], designed)

    # With the Plan Review state turned off, a plan waits in the review states as before.
    off = %{designed | tracker: %{designed.tracker | plan_review_state: nil}}
    assert Waiting.entries([plan], off) == []
    assert [%{identifier: "TP-20", kind: :plan}] = Waiting.entries([%{plan | "state" => %{"name" => "In Review"}}], off)
  end

  test "an open request makes the issue an action, waiting since the request when its history has no move" do
    action = node("TP-4", %{"state" => %{"name" => "Human Review"}, "labels" => labels(["plan"]), "comments" => comments([request_comment("2026-10-02T07:00:00Z")])})

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

  test "a held ticket with no request waits since the move into its state" do
    held =
      node("TP-12", %{
        "state" => %{"name" => "Human Review"},
        "history" => history([moved("In Review", "2026-10-01T09:00:00Z"), moved("Human Review", "2026-10-01T11:00:00Z")])
      })

    assert [%{identifier: "TP-12", kind: :pr, waiting_since: ~U[2026-10-01 11:00:00Z]}] = entries([held])
  end

  test "skips issues outside a review state with no open request, and nodes without an id" do
    assert entries([node("TP-5", %{"state" => %{"name" => "Todo"}}), node("TP-6", %{"state" => nil}), %{"identifier" => "TP-7"}]) == []
  end

  test "an issue with no state change or request into its state waits since nil" do
    stray =
      node("TP-8", %{
        "history" =>
          history([
            moved("Todo", "2026-10-01T08:00:00Z"),
            %{"createdAt" => "soon", "toState" => %{"name" => "In Review"}},
            %{"createdAt" => nil, "toState" => %{"name" => "In Review"}},
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
