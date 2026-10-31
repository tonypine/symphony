defmodule SymphonyElixir.NeedsDecisionHoldTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.NeedsDecisionHold

  # The request as the tool builds it from the agent's attrs: what `Request.render_hold/2` renders.
  defp request(attrs \\ %{}) do
    Map.merge(
      %{
        title: "Add the release signing secrets",
        question: "Add the signing secrets, or ship unsigned builds?",
        why: "Every Release run on main fails without them.",
        unblocks: "the Release workflow on main",
        if_unanswered: "Every Release run on main keeps failing.",
        options: [%{label: "Add the secrets", effect: "Releases are signed again.", recommended: true}, %{label: "Ship unsigned", effect: "The agent drops the signing step."}],
        recommendation_reason: "Signing is a one-time setup.",
        steps: [],
        created_at: nil
      },
      attrs
    )
  end

  # The request as Linear reads it back: the comment parsed, its options as rendered lines.
  defp parsed_request(attrs \\ %{}) do
    request() |> Request.render_hold("In Progress") |> Request.parse(DateTime.utc_now()) |> Map.merge(attrs)
  end

  describe "desired/2" do
    test "an open request with no hold wants the hold set with the decision recorded" do
      assert {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)
      assert attrs.reason == "Add the signing secrets, or ship unsigned builds?"
      assert attrs.clearing_condition == "when the decision is recorded"
      assert attrs.decision.question == "Add the signing secrets, or ship unsigned builds?"
      assert attrs.decision.title == "Add the release signing secrets"
      assert attrs.decision.why == "Every Release run on main fails without them."
      assert attrs.decision.options == ["**Add the secrets** (recommended): Releases are signed again.", "**Ship unsigned**: The agent drops the signing step."]
    end

    test "a request with no question records its title as the reason" do
      assert {:set, %{reason: "Add the release signing secrets"}} = NeedsDecisionHold.desired(parsed_request(%{question: nil}), nil)
    end

    test "a hold that already carries the request wants nothing" do
      {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)

      assert NeedsDecisionHold.desired(parsed_request(), %{kind: :needs_decision, decision: attrs.decision}) == :none
    end

    test "a hold carrying a different request is replaced" do
      {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)
      other = parsed_request(%{title: "Something else", question: "Something else?"})

      assert {:set, %{decision: %{title: "Something else"}}} =
               NeedsDecisionHold.desired(other, %{kind: :needs_decision, decision: attrs.decision})
    end

    test "no open request clears the hold it left behind and leaves other holds alone" do
      assert NeedsDecisionHold.desired(nil, %{kind: :needs_decision}) == :clear
      assert NeedsDecisionHold.desired(nil, %{kind: :blocked}) == :none
      assert NeedsDecisionHold.desired(nil, nil) == :none
    end
  end

  describe "attrs/1" do
    test "the tool's own request, not read back yet, records no asked time" do
      assert %{decision: %{title: "Add the release signing secrets", asked_at: nil}} = NeedsDecisionHold.attrs(request())
    end
  end
end
