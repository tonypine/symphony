defmodule SymphonyElixir.GitHub.CommentMarker do
  @moduledoc """
  Tags PR comments Symphony posts so the review poller can tell them apart from
  reviewer feedback left by the same GitHub account.

  Symphony pushes and comments with the operator's `gh` account, so authorship
  alone cannot separate agent replies from the operator's own review comments.
  Every comment body Symphony posts carries a hidden HTML marker instead.
  """

  @marker "<!-- symphony:agent -->"
  # Replies posted before the marker existed still open with these phrases
  # (poller auto-replies and the workflow's suggested agent reply wording).
  @legacy_prefixes ["automated note from symphony ai", "symphony ai "]

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec mark(String.t()) :: String.t()
  def mark(body) when is_binary(body) do
    if String.contains?(body, @marker), do: body, else: body <> "\n\n" <> @marker
  end

  @spec symphony_authored?(term()) :: boolean()
  def symphony_authored?(body) when is_binary(body) do
    normalized = body |> String.trim_leading() |> String.downcase()

    String.contains?(body, @marker) or String.starts_with?(normalized, @legacy_prefixes)
  end

  def symphony_authored?(_body), do: false
end
