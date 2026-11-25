defmodule SymphonyElixir.QaDriver.Pages do
  @moduledoc """
  The pages of Symphony.app's window `qa_launch_app` opens the app on (`page`), and the ticket
  page it opens on (`ticket`): the app reads them from `SYMPHONY_BAR_QA_OPEN_VIEW` and
  `SYMPHONY_BAR_QA_OPEN_TICKET` at launch (`macos/Sources/SymphonyBarCore/QAMode.swift`).

  The list mirrors the app's `SymphonyView` (name and title, in sidebar order); a test reads the
  Swift enum, so the two cannot drift apart. A page is named by its name (`overview`) or its title
  (`Home`), whatever the case.

  `place/1` reads a QA plan's free-text setting `page` ("Tickets", "the Home page", "TP-12's
  page"): a ticket identifier in it is that ticket's page, else a page's name or title, with a
  leading "the" and a trailing "page" or "tab" left out. Text that names neither is `:unknown`.
  """

  @pages [
    {"inbox", "Inbox"},
    {"overview", "Home"},
    {"journal", "Journal"},
    {"initiatives", "Initiatives"},
    {"tickets", "Tickets"},
    {"quality", "Quality"},
    {"usage", "Usage"},
    {"shipped", "Shipped"},
    {"audit", "Audit"},
    {"setup", "Setup"},
    {"repos", "Repos"},
    {"runs", "Runs"},
    {"providers", "Providers"},
    {"diagnostics", "Diagnostics"},
    {"settings", "Settings"}
  ]

  @ticket ~r/\b([A-Za-z][A-Za-z0-9]*-[0-9]+)\b/
  @ticket_only ~r/^[A-Za-z][A-Za-z0-9]*-[0-9]+$/

  @typedoc "A page of the window: its name, as the app reads it, and its title, as its sidebar shows it."
  @type page :: %{name: String.t(), title: String.t()}

  @doc "Every page of the window, in sidebar order."
  @spec all() :: [page()]
  def all, do: Enum.map(@pages, fn {name, title} -> %{name: name, title: title} end)

  @doc "The pages, as a tool error lists them: `overview` (Home), `tickets` (Tickets), …"
  @spec listing() :: String.t()
  def listing, do: Enum.map_join(@pages, ", ", fn {name, title} -> "`#{name}` (#{title})" end)

  @doc "The page `text` names by its name or title, whatever the case and surrounding spaces; `:error` for none."
  @spec named(String.t()) :: {:ok, page()} | :error
  def named(text) when is_binary(text) do
    wanted = text |> String.trim() |> String.downcase()

    case Enum.find(@pages, fn {name, title} -> wanted in [name, String.downcase(title)] end) do
      {name, title} -> {:ok, %{name: name, title: title}}
      nil -> :error
    end
  end

  @doc "Whether `text` is a ticket identifier, such as `TP-12`."
  @spec ticket?(term()) :: boolean()
  def ticket?(text) when is_binary(text), do: Regex.match?(@ticket_only, text)
  def ticket?(_text), do: false

  @doc """
  Where a plan's setting `page` opens the app: `{:ticket, identifier}` when it names a ticket,
  `{:page, page}` when it names a page of the window, else `:unknown`.
  """
  @spec place(term()) :: {:ticket, String.t()} | {:page, page()} | :unknown
  def place(text) when is_binary(text) do
    with nil <- Regex.run(@ticket, text),
         {:ok, page} <- text |> bare() |> named() do
      {:page, page}
    else
      [_match, identifier] -> {:ticket, String.upcase(identifier)}
      :error -> :unknown
    end
  end

  def place(_text), do: :unknown

  defp bare(text) do
    text
    |> String.trim()
    |> String.replace(~r/^the\s+/i, "")
    |> String.replace(~r/\s+(page|tab)$/i, "")
  end
end
