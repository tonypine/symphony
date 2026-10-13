defmodule SymphonyElixirWeb.LearningsLive do
  @moduledoc """
  Read-only dashboard for captured run learnings.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Learnings.{Feed, Store}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :payload, payload(params))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell learnings-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Learnings</p>
            <h1 class="hero-title">Learnings</h1>
            <p class="hero-copy">Captured run-end reflections from merged Symphony pull requests.</p>
          </div>

          <div class="status-stack">
            <a class="action-pill hero-action" href="/">Dashboard</a>
            <a class="action-pill hero-action" href="/audit">Audit</a>
            <a class="action-pill hero-action" href="/quality">Quality</a>
          </div>
        </div>
      </header>

      <%= if @payload.error do %>
        <section class="error-card">
          <h2 class="error-title">Learnings unavailable</h2>
          <p class="error-copy"><%= @payload.error %></p>
        </section>
      <% else %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Filters</h2>
            </div>
          </div>

          <form class="quality-filter-form" method="get" action="/learnings">
            <label class="quality-field">
              <span>Repo</span>
              <select name="repo">
                <option value="" selected={blank?(@payload.filters.repo)}>All</option>
                <option :for={repo <- @payload.repos} value={repo} selected={@payload.filters.repo == repo}><%= repo %></option>
              </select>
            </label>

            <label class="quality-field">
              <span>Tag</span>
              <select name="tag">
                <option value="" selected={blank?(@payload.filters.tag)}>All</option>
                <option :for={tag <- @payload.tags} value={tag} selected={@payload.filters.tag == tag}><%= tag %></option>
              </select>
            </label>

            <button type="submit" class="quality-submit">Apply</button>
          </form>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Records</h2>
              <p class="section-copy"><%= length(@payload.records) %> matching learnings.</p>
            </div>
          </div>

          <%= if @payload.records == [] do %>
            <p class="empty-state">No learnings match the current filters.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table learnings-table">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 28%;" />
                  <col style="width: 16rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Repo</th>
                    <th>Rule</th>
                    <th>Tags</th>
                    <th>Evidence</th>
                    <th>Source</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.records}>
                    <td class="mono"><%= repo_label(entry) %></td>
                    <td><strong><%= entry.rule %></strong></td>
                    <td>
                      <div class="tag-list">
                        <span :for={tag <- entry.tags} class="tag-pill"><%= tag %></span>
                      </div>
                    </td>
                    <td><p class="learning-evidence"><%= entry.evidence_quote %></p></td>
                    <td>
                      <div class="link-actions">
                        <a :if={pr_href(entry)} class="action-pill" href={pr_href(entry)} target="_blank">PR</a>
                        <a :if={linear_href(entry)} class="action-pill" href={linear_href(entry)} target="_blank">Linear</a>
                      </div>
                      <span :if={entry.evidence_run_id} class="muted mono"><%= short_id(entry.evidence_run_id) %></span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp payload(params) do
    filters = %{
      repo: normalize_filter(Map.get(params, "repo")),
      tag: normalize_filter(Map.get(params, "tag"))
    }

    case Store.list() do
      records when is_list(records) ->
        %{
          error: nil,
          filters: filters,
          repos: records |> Enum.map(&repo_label/1) |> Enum.reject(&blank?/1) |> Enum.uniq() |> Enum.sort(),
          tags: records |> Enum.flat_map(&Map.get(&1, :tags, [])) |> Enum.uniq() |> Enum.sort(),
          records: filter_records(records, filters)
        }

      {:error, reason} ->
        %{error: inspect(reason), filters: filters, repos: [], tags: [], records: []}
    end
  end

  defp filter_records(records, filters) do
    Enum.filter(records, fn record ->
      matches_filter?(repo_label(record), filters.repo) and matches_tag?(Map.get(record, :tags, []), filters.tag)
    end)
  end

  defp matches_filter?(_value, nil), do: true
  defp matches_filter?(value, filter), do: value == filter

  defp matches_tag?(_tags, nil), do: true
  defp matches_tag?(tags, tag) when is_list(tags), do: tag in tags
  defp matches_tag?(_tags, _tag), do: false

  defp normalize_filter(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_filter(_value), do: nil

  defp pr_href(entry), do: Feed.pr_url(entry)
  defp linear_href(entry), do: Feed.issue_url(entry)
  defp repo_label(entry), do: Feed.repo_label(entry)

  defp short_id(value) when is_binary(value) and byte_size(value) > 8, do: binary_part(value, 0, 8)
  defp short_id(value), do: value

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
