defmodule SymphonyElixir.GitHub.CommentMarkerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.CommentMarker

  test "mark appends the hidden marker once" do
    marked = CommentMarker.mark("Fixed in abc123.")

    assert marked == "Fixed in abc123.\n\n" <> CommentMarker.marker()
    assert CommentMarker.mark(marked) == marked
  end

  test "symphony_authored? recognizes marked bodies and legacy Symphony replies" do
    assert CommentMarker.symphony_authored?(CommentMarker.mark("Done."))
    assert CommentMarker.symphony_authored?("  Symphony AI handled this in abc123: renamed the helper.")
    assert CommentMarker.symphony_authored?("Automated note from Symphony AI: this review comment was marked complete.")

    refute CommentMarker.symphony_authored?("Please rename this helper.")
    refute CommentMarker.symphony_authored?("Symphony AIs should not match.")
    refute CommentMarker.symphony_authored?(nil)
  end
end
