defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, ForcedStatus, URLUtils, UsageLimit}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @dashboard_reload_task :dashboard_reload
  @default_control_confirm_timeout_ms 10_000
  @dashboard_pause_reason "Paused from dashboard"
  @recent_runs_limit 10

  @impl true
  def mount(params, _session, socket) do
    payload = load_payload()
    repo_filter = normalize_repo_filter(Map.get(params, "repo"), payload)

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:repo_filter, repo_filter)
      |> assign(:visible_payload, filter_payload(payload, repo_filter))
      |> assign(:dashboard_refreshing?, false)
      |> assign(:now, DateTime.utc_now())
      |> assign(:pending_control, nil)
      |> assign(:pending_control_token, nil)
      |> assign(:control_error, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    repo_filter = normalize_repo_filter(Map.get(params, "repo"), socket.assigns.payload)

    {:noreply, assign_repo_filter(socket, repo_filter)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:observability_updated, %{repo_key: _repo_key}}, socket) do
    {:noreply, queue_dashboard_reload(socket)}
  end

  def handle_info({:disarm_control, token}, %{assigns: %{pending_control_token: token}} = socket) do
    {:noreply, disarm_control(socket)}
  end

  def handle_info({:disarm_control, _token}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("arm-pause", _params, socket) do
    {:noreply, arm_control(socket, :pause)}
  end

  def handle_event("pause-dispatch", _params, socket) do
    result = SymphonyElixir.Orchestrator.pause_dispatch(orchestrator(), @dashboard_pause_reason)
    {:noreply, reload_after_control(socket, result)}
  end

  def handle_event("arm-resume", _params, socket) do
    {:noreply, arm_control(socket, :resume)}
  end

  def handle_event("resume-dispatch", _params, socket) do
    result = SymphonyElixir.Orchestrator.resume_dispatch(orchestrator())
    {:noreply, reload_after_control(socket, result)}
  end

  def handle_event("filter-repo", %{"repo" => repo_filter}, socket) do
    repo_filter = normalize_repo_filter(repo_filter, socket.assigns.payload)

    {:noreply,
     socket
     |> assign_repo_filter(repo_filter)
     |> push_patch(to: dashboard_filter_path(repo_filter))}
  end

  def handle_event("arm-stop", %{"issue-id" => issue_id}, socket) do
    {:noreply, arm_control(socket, {:stop, issue_id})}
  end

  def handle_event("stop-running", %{"issue-id" => issue_id}, socket) do
    result = SymphonyElixir.Orchestrator.stop_running(orchestrator(), issue_id)
    {:noreply, reload_after_control(socket, result)}
  end

  @impl true
  def handle_async(@dashboard_reload_task, {:ok, payload}, socket) do
    {:noreply,
     socket
     |> assign_payload(payload)
     |> assign(:dashboard_refreshing?, false)
     |> assign(:control_error, nil)
     |> assign(:now, DateTime.utc_now())}
  end

  def handle_async(@dashboard_reload_task, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :dashboard_refreshing?, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
            <a class="action-pill" href="/audit">Audit</a>
            <a class="action-pill" href="/quality">Quality Dashboard →</a>
            <a class="action-pill" href="/learnings">Learnings →</a>
            <%= if !@payload[:error] && @payload.pause.paused do %>
              <div class="system-paused-banner">
                <strong>System paused</strong>
                <span><%= @payload.pause.reason || "Dispatch is paused for all repos." %></span>
              </div>
            <% end %>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section :if={@payload.usage_limits != []} class="usage-limit-banner" role="status">
          <p :for={usage_limit <- @payload.usage_limits} class="usage-limit-banner-line">
            <%= UsageLimit.banner(usage_limit, @now) %>
          </p>
        </section>

        <section :if={@payload.stray_processes != []} class="stray-process-banner" role="alert">
          <p class="stray-process-banner-title">Processes using CPU with no run attached</p>
          <ul class="stray-process-list">
            <li :for={process <- @payload.stray_processes} class="stray-process-line">
              <strong>pid <%= process.pid %></strong>
              <code class="stray-process-command"><%= process.command %></code>
              <span class="muted">in <%= process.cwd || "an unknown folder" %></span>
              <span class="numeric"><%= format_runtime_seconds(process.cpu_seconds) %> CPU</span>
            </li>
          </ul>
        </section>

        <section class={["ops-control-card", !@payload.dispatch_state.active? && "ops-control-card-paused"]}>
          <div class="ops-control-main">
            <div class="ops-control-copy">
              <span class={if @payload.dispatch_state.active?, do: "state-badge state-badge-active", else: "state-badge state-badge-warning"}>
                Dispatch <%= if @payload.dispatch_state.active?, do: "active", else: "paused" %>
              </span>
              <%= if !@payload.dispatch_state.active? do %>
                <ul class="ops-control-blockers">
                  <%= for blocker <- @payload.dispatch_state.blockers do %>
                    <li class={"ops-control-blocker ops-control-blocker-#{blocker.kind}"}>
                      <strong><%= blocker_label(blocker) %></strong>
                      <span class="muted"><%= blocker_detail(blocker) %></span>
                    </li>
                  <% end %>
                </ul>
              <% end %>
              <%= if @control_error do %>
                <p class="ops-control-error"><%= @control_error %></p>
              <% end %>
            </div>

            <div class="ops-control-actions">
              <%= if @payload.pause.paused do %>
                <%= if @pending_control == :resume do %>
                  <button type="button" phx-click="resume-dispatch">Confirm Resume</button>
                <% else %>
                  <button type="button" class="secondary" phx-click="arm-resume">Resume All</button>
                <% end %>
              <% else %>
                <%= if @pending_control == :pause do %>
                  <button type="button" class="danger-button" phx-click="pause-dispatch">Confirm Pause</button>
                <% else %>
                  <button type="button" class="secondary pause-dispatch-button" phx-click="arm-pause">Pause All</button>
                <% end %>
              <% end %>
            </div>
          </div>
        </section>

        <section class="dashboard-filter-card">
          <form phx-change="filter-repo">
            <label class="dashboard-filter-field">
              <span>Repo</span>
              <select name="repo" aria-label="Dashboard repository filter">
                <option value="" selected={@repo_filter == nil}>All</option>
                <option :for={repo <- @payload.repos} value={repo} selected={@repo_filter == repo}><%= repo %></option>
              </select>
            </label>
          </form>
          <span :if={@dashboard_refreshing?} class="dashboard-refresh-status">Updating...</span>
        </section>

        <section class="metric-grid dashboard-metrics">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @visible_payload.counts.running %></p>
            <p class="metric-detail">active</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Watching</p>
            <p class="metric-value numeric"><%= @visible_payload.counts.watching %></p>
            <p class="metric-detail">waiting</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Human Review</p>
            <p class="metric-value numeric"><%= @visible_payload.counts.human_review %></p>
            <p class="metric-detail">needs you</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @visible_payload.counts.retrying %></p>
            <p class="metric-detail">backoff</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Conflict</p>
            <p class="metric-value numeric"><%= @visible_payload.counts.conflicts %></p>
            <p class="metric-detail">blocked</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Forced</p>
            <p class="metric-value numeric"><%= @payload.counts.forced %>/<%= forced_max(@payload) %></p>
            <p class="metric-detail">forced_max</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Daily tokens</p>
            <p class="metric-value numeric"><%= format_budget_usage(@payload.budget.daily_used, @payload.budget.daily_limit) %></p>
            <p class="metric-detail"><%= daily_budget_detail(@payload.budget) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Issue budget</p>
            <p class="metric-value numeric"><%= format_budget_limit(@payload.budget.per_issue_limit) %></p>
            <p class="metric-detail">per issue</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">completed + active</p>
          </article>
        </section>

        <section class="section-card" id="waiting-on-you">
          <div class="section-header">
            <div>
              <h2 class="section-title">Waiting on you</h2>
              <p class="section-copy">Tickets in review, or with a decision only you can make, oldest first.</p>
            </div>
          </div>

          <%= if @payload.waiting_on_you == [] do %>
            <p class="empty-state">Nothing waits on you.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Kind</th>
                    <th>What to review</th>
                    <th>Waiting since</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.waiting_on_you} class="waiting-on-you-row">
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer" title={entry.title}><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id" title={entry.title}><%= entry.issue_identifier %></span>
                        <% end %>
                        <span class="muted"><%= entry.state %></span>
                      </div>
                    </td>
                    <td><%= waiting_kind_label(entry.kind) %></td>
                    <td><%= entry.headline || entry.title %></td>
                    <td class="numeric"><%= format_ago(seconds_since(entry.waiting_since, @now)) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Linear requests</h2>
              <p class="section-copy">
                Requests sent to Linear in the last hour, by caller: <span class="numeric"><%= @payload.linear_usage.total %></span> in total.
              </p>
            </div>
          </div>

          <%= if @payload.linear_usage.callers == [] do %>
            <p class="empty-state">No Linear requests in the last hour.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Caller</th>
                    <th>Requests</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={caller <- @payload.linear_usage.callers}>
                    <td><%= caller.caller %></td>
                    <td class="numeric"><%= caller.requests %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">GitHub webhooks</h2>
              <p class="section-copy">CI results from a webhook relay land in seconds; the CI poll still runs and catches up on anything the relay misses.</p>
            </div>
          </div>

          <%= case github_webhooks(@payload) do %>
            <% nil -> %>
              <p class="empty-state">The CI poller is not running.</p>
            <% %{enabled: false} -> %>
              <p class="empty-state">Off. CI results arrive by polling only.</p>
            <% webhooks -> %>
              <div class="table-wrap">
                <table class="data-table">
                  <tbody>
                    <tr>
                      <th>Status</th>
                      <td>Active through <%= webhooks.relay %></td>
                    </tr>
                    <tr>
                      <th>Last event</th>
                      <td class="numeric"><%= format_event_at(webhooks.last_event_at, @now) || "none yet" %></td>
                    </tr>
                    <tr>
                      <th>Events received</th>
                      <td class="numeric"><%= webhooks.events_received %> (<%= webhooks.rejected %> rejected)</td>
                    </tr>
                    <tr>
                      <th>CI results</th>
                      <td class="numeric"><%= webhooks.results_via_webhook %> via relay, <%= webhooks.results_via_poll %> by polling</td>
                    </tr>
                  </tbody>
                </table>
              </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Agent lanes</h2>
              <p class="section-copy">
                Each active epic keeps a lane for its sub-tickets and the tickets blocking them, and yields it while they all wait on people. Shared pool: <span class="numeric"><%= @payload.epic_lanes.shared.used %>/<%= @payload.epic_lanes.shared.slots %></span> in use.
              </p>
            </div>
          </div>

          <%= if @payload.epic_lanes.lanes == [] do %>
            <p class="empty-state">No active epics; every slot is shared.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-lanes">
                <thead>
                  <tr>
                    <th>Epic</th>
                    <th>Lane</th>
                    <th>Ticket</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={lane <- @payload.epic_lanes.lanes}>
                    <td>
                      <div class="issue-stack">
                        <a class="issue-id" href={lane.url} target="_blank" rel="noreferrer"><%= lane.identifier %></a>
                        <span class="muted"><%= lane.title %></span>
                      </div>
                    </td>
                    <td>
                      <span class={if lane.status == "running", do: "state-badge state-badge-active", else: "state-badge"}>
                        <%= lane_status_label(lane.status) %>
                      </span>
                    </td>
                    <td><%= lane_part_label(lane) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>

          <%= if @payload.epic_lanes.queued_epics != [] do %>
            <p class="section-copy">
              Waiting for a lane: <%= Enum.map_join(@payload.epic_lanes.queued_epics, ", ", & &1.identifier) %>
            </p>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Finishing runs</h2>
              <p class="section-copy">
                Landing runs use their own slots, outside the agent slots and lanes: <span class="numeric"><%= @payload.finishing.used %>/<%= @payload.finishing.slots %></span> in use.
                <%= if @payload.finishing.running != [] do %>
                  Landing: <%= Enum.map_join(@payload.finishing.running, ", ", & &1.identifier) %>
                <% end %>
              </p>
              <p :for={entry <- Map.get(@payload, :auto_merge, [])} class="section-copy">
                <%= entry.issue_identifier %>: <%= entry.status %>
              </p>
            </div>
          </div>

          <%= if @payload.slot_waiting == [] do %>
            <p class="empty-state">Nothing is waiting to start.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Waiting to start</th>
                    <th>State</th>
                    <th>Why</th>
                    <th>Attempt</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.slot_waiting}>
                    <td><.forced_marker forced={entry.forced} /><span class="issue-id"><%= entry.issue_identifier %></span></td>
                    <td><%= entry.state %></td>
                    <td><%= entry.reason %></td>
                    <td class="numeric"><%= entry.attempt || "-" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>

          <%= if @payload.blocked != [] do %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Waiting on blockers</th>
                    <th>State</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td><%= entry.summary %></td>
                    <td><%= entry.state %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Auto Review</h2>
              <p class="section-copy">
                Acceptance gate: <%= gate_runner_line(@payload.acceptance_gate) %>
              </p>
              <p :for={{repo_key, stats} <- Enum.sort(@payload.acceptance_gate.agreement)} class="section-copy">
                <%= gate_agreement_line(repo_key, stats) %>
              </p>
            </div>
          </div>

          <%= if @payload.acceptance_gate.recent == [] do %>
            <p class="empty-state">The acceptance gate has not judged a ticket yet.</p>
          <% else %>
            <p :for={entry <- @payload.acceptance_gate.recent} class="section-copy">
              <%= gate_verdict_line(entry) %>
            </p>
          <% end %>
        </section>

        <section :if={@payload.forced != []} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Forced</h2>
              <p class="section-copy">
                Tickets a human forced through to Done, earliest first. Up to <span class="numeric"><%= forced_max(@payload) %></span> run at once on the forced allowance, outside the agent slots.
              </p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Phase</th>
                  <th>Waiting on</th>
                  <th>Forced for</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.forced}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id" title={entry.title}><.forced_marker forced={true} /><%= entry.issue_identifier %></span>
                      <span :if={entry.sub_issue} class="muted">now <%= entry.sub_issue.issue_identifier %> (<%= entry.sub_issue.state %>)</span>
                    </div>
                  </td>
                  <td><%= ForcedStatus.phase_label(entry.phase) %></td>
                  <td><%= ForcedStatus.waiting_label(entry) %></td>
                  <td>
                    <span class="numeric"><%= ForcedStatus.duration_label(entry.forced_for_seconds) %></span>
                    <span :if={entry.stale} class="state-badge state-badge-danger">Stale</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @visible_payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 9rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 8rem;" />
                  <col />
                  <col style="width: 9rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 7rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Agent update</th>
                    <th>Tokens</th>
                    <th>Links</th>
                    <th>Control</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @visible_payload.running}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer" title={entry.title}><.forced_marker forced={entry.forced} /><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id" title={entry.title}><.forced_marker forced={entry.forced} /><%= entry.issue_identifier %></span>
                        <% end %>
                        <.repo_chip repo={repo_label(entry)} />
                        <span :if={entry.run_kind == :pr || entry.run_kind == "pr"} class="repo-chip repo-chip-pr">
                          <span class="repo-chip-text">PR</span>
                        </span>
                        <span :if={entry[:run_profile]} class="muted run-profile" title="Run kind · model · effort"><%= entry.run_profile.label %></span>
                        <span :if={entry[:reviewer_profile]} class="muted run-profile" title="Pre-push reviewer: run kind · model · effort">Reviewer: <%= entry.reviewer_profile.label %></span>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button session-copy-btn"
                            aria-label="Copy ID"
                            data-label={String.slice(entry.session_id, 0, 8) <> "…"}
                            data-copy={entry.session_id}
                            title={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied ✓'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1400);"
                          >
                            <%= String.slice(entry.session_id, 0, 8) %>…
                          </button>
                        <% else %>
                          <span class="muted">—</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= if entry.last_event_at do %>
                            <span class="numeric"><%= format_event_at(entry.last_event_at, @now) %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <%= if issue_budget_limited?(@payload.budget.per_issue_limit) do %>
                          <span class="muted">Budget: <%= format_issue_budget_remaining(entry.tokens.total_tokens, @payload.budget.per_issue_limit) %> left</span>
                        <% end %>
                        <span class="muted">New <%= format_int(entry.tokens.uncached_input_tokens) %> / Cached <%= format_int(entry.tokens.cached_input_tokens) %></span>
                        <span class="muted">Created <%= format_int(entry.tokens.cache_creation_input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                    <td class="links-cell">
                      <div class="link-actions">
                        <a :if={entry.pull_request_url} class="action-pill" href={entry.pull_request_url} target="_blank" rel="noreferrer">PR</a>
                        <a class="action-pill" href={transcript_path(entry)}>Transcript</a>
                        <a class="action-pill" href={audit_path(entry)}>Audit</a>
                        <a class="action-pill" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                    <td class="links-cell">
                      <%= if pending_stop?(@pending_control, entry.issue_id) do %>
                        <button
                          type="button"
                          class="subtle-button danger-subtle-button"
                          phx-click="stop-running"
                          phx-value-issue-id={entry.issue_id}
                        >
                          Confirm Stop
                        </button>
                      <% else %>
                        <button
                          type="button"
                          class="subtle-button danger-subtle-button"
                          phx-click="arm-stop"
                          phx-value-issue-id={entry.issue_id}
                        >
                          Stop
                        </button>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent runs</h2>
              <p class="section-copy">The latest runs with the kind, model and effort each one started with.</p>
            </div>
          </div>

          <%= if recent_runs(@visible_payload) == [] do %>
            <p class="empty-state">No runs yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-recent-runs">
                <colgroup>
                  <col style="width: 9rem;" />
                  <col style="width: 10rem;" />
                  <col />
                  <col style="width: 9rem;" />
                  <col style="width: 9rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Run kind</th>
                    <th>Model / effort</th>
                    <th>Status</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- recent_runs(@visible_payload)}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id" title={run.title}><%= run.issue_identifier %></span>
                        <.repo_chip repo={repo_label(run)} />
                      </div>
                    </td>
                    <td><%= run.run_kind || run.kind %></td>
                    <td>
                      <div class="detail-stack">
                        <span><%= profile_value(run.model) %> · <%= profile_value(run.effort) %></span>
                        <span :if={run.reviewer_profile} class="muted">
                          Reviewer: <%= profile_value(run.reviewer_profile.model) %> · <%= profile_value(run.reviewer_profile.effort) %>
                        </span>
                      </div>
                    </td>
                    <td><%= run.status %></td>
                    <td class="numeric"><%= format_int(Map.get(run.tokens || %{}, :total_tokens, 0)) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Watching</h2>
              <p class="section-copy">Recently handled issues waiting outside active and terminal workflow states.</p>
            </div>
          </div>

          <%= if @visible_payload.watching == [] do %>
            <p class="empty-state">No watched issues.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-watching">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 13rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Last run</th>
                    <th>Links</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @visible_payload.watching}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer" title={entry.title}><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id" title={entry.title}><%= entry.issue_identifier %></span>
                        <% end %>
                        <.repo_chip repo={repo_label(entry)} />
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_last_run(entry, @now) %></td>
                    <td class="links-cell">
                      <div class="link-actions">
                        <%= if entry.pull_request_url do %>
                          <a class="action-pill" href={entry.pull_request_url} target="_blank" rel="noreferrer">PR</a>
                        <% end %>
                        <a class="action-pill" href={transcript_path(entry)}>Transcript</a>
                        <a class="action-pill" href={audit_path(entry)}>Audit</a>
                        <a class="action-pill" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Conflict</h2>
              <p class="section-copy">Issues currently claimed by more than one repo in the latest poll cycle.</p>
            </div>
          </div>

          <%= if @visible_payload.conflicts == [] do %>
            <p class="empty-state">No repo conflicts.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-conflict">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 9rem;" />
                  <col />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Conflicting repos</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @visible_payload.conflicts}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer" title={entry.title}><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id" title={entry.title}><%= entry.issue_identifier %></span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class="state-badge state-badge-danger">Conflict</span>
                    </td>
                    <td>
                      <div class="repo-chip-list">
                        <%= for repo <- conflict_repos(entry) do %>
                          <.repo_chip repo={repo} class="repo-chip-conflict" />
                        <% end %>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @visible_payload.retrying == [] do %>
            <p class="empty-state">No queued retries</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @visible_payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id" title={entry.title}><.forced_marker forced={entry.forced} /><%= entry.issue_identifier %></span>
                        <.repo_chip repo={repo_label(entry)} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Awaiting clarification</h2>
              <p class="section-copy">Quality-gate holds waiting for clearer issue context.</p>
            </div>
          </div>

          <%= if @visible_payload.awaiting_clarification == [] do %>
            <p class="empty-state">No issues awaiting clarification</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-quality">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 7rem;" />
                  <col />
                  <col style="width: 12rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Round</th>
                    <th>Score</th>
                    <th>Reason</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @visible_payload.awaiting_clarification}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer" title={entry.title}><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id" title={entry.title}><%= entry.issue_identifier %></span>
                        <% end %>
                        <.repo_chip repo={repo_label(entry)} />
                      </div>
                    </td>
                    <td class="numeric"><%= format_optional_int(entry.rounds_asked) %></td>
                    <td class="numeric"><%= format_optional_int(entry.score) %></td>
                    <td>
                      <span class="event-text" title={entry.reason || "n/a"}><%= entry.reason || "n/a" %></span>
                    </td>
                    <td class="mono"><%= entry.updated_at || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Skipped (quality gate)</h2>
              <p class="section-copy">Issues rejected by the quality gate before dispatch.</p>
            </div>
          </div>

          <%= if @visible_payload.skipped == [] do %>
            <p class="empty-state">No issues skipped this session</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-quality">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7rem;" />
                  <col />
                  <col style="width: 12rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Result</th>
                    <th>Score</th>
                    <th>Detail</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @visible_payload.skipped}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer" title={entry.title}><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id" title={entry.title}><%= entry.issue_identifier %></span>
                        <% end %>
                        <.repo_chip repo={repo_label(entry)} />
                      </div>
                    </td>
                    <td>
                      <span class={quality_gate_badge_class(entry)}>
                        <%= quality_gate_kind_label(entry) %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_optional_int(entry.score) %></td>
                    <td>
                      <span class="event-text" title={quality_gate_detail(entry)}>
                        <%= quality_gate_detail(entry) %>
                      </span>
                    </td>
                    <td class="mono"><%= entry.updated_at || "n/a" %></td>
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

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), stray_processes(), human_actions())
  end

  defp queue_dashboard_reload(socket) do
    socket
    |> assign(:dashboard_refreshing?, true)
    |> start_async(@dashboard_reload_task, fn -> load_payload() end)
  end

  defp assign_repo_filter(socket, repo_filter) do
    socket
    |> assign(:repo_filter, repo_filter)
    |> assign(:visible_payload, filter_payload(socket.assigns.payload, repo_filter))
  end

  defp assign_payload(socket, payload) do
    repo_filter = normalize_repo_filter(socket.assigns.repo_filter, payload)

    socket
    |> assign(:payload, payload)
    |> assign(:repo_filter, repo_filter)
    |> assign(:visible_payload, filter_payload(payload, repo_filter))
  end

  defp gate_runner_line(%{running: running, queued: queued}) do
    names = if running == [], do: "", else: " (#{Enum.map_join(running, ", ", & &1.identifier)})"
    "#{length(running)} running#{names}, #{length(queued)} queued."
  end

  defp gate_verdict_line(entry) do
    agent = if entry.agent_verdict in [nil, entry.verdict], do: "", else: " (agent: #{entry.agent_verdict})"
    reasons = if entry.reasons == [], do: "", else: " · reasons: #{Enum.map_join(entry.reasons, ", ", & &1.rule)}"
    %{met: met, unmet: unmet, unclear: unclear} = entry.criteria

    "#{entry.issue_identifier}: #{entry.verdict}#{agent} · #{met} met, #{unmet} unmet, #{unclear} unclear#{reasons} · " <>
      "#{entry.mode} · human: #{entry.human_decision || "waiting"}"
  end

  defp gate_agreement_line(repo_key, stats) do
    readiness = if stats.ready_to_enforce, do: "ready to enforce", else: "not ready to enforce: #{stats.unmet_condition}"

    "#{repo_key}: #{stats.judged} judged, #{stats.agreed} agreed (#{rate_label(stats.agreement_rate)}), " <>
      "#{stats.unsafe_approvals} unsafe approvals, #{stats.false_reworks} false reworks, " <>
      "#{stats.escalations} escalations (#{stats.escalations_merged_unchanged} merged unchanged), " <>
      "gate tokens median #{stats.tokens.median || "n/a"}, p90 #{stats.tokens.p90 || "n/a"} · #{readiness}"
  end

  defp rate_label(nil), do: "n/a"
  defp rate_label(rate), do: "#{round(rate * 100)}%"

  defp lane_status_label("running"), do: "Running"
  defp lane_status_label("yielded"), do: "Yielded"
  defp lane_status_label(_status), do: "Idle, reserved"

  defp lane_part_label(%{status: "yielded", reason: reason}), do: reason

  defp lane_part_label(%{status: "running", sub_issue: %{identifier: identifier, state: state} = part}),
    do: "#{identifier} (#{state})" <> lane_part_via(Map.get(part, :via))

  defp lane_part_label(%{sub_issue: %{identifier: identifier, state: state}}), do: "Waiting on #{identifier} (#{state})"
  defp lane_part_label(_lane), do: "Waiting for its next sub-ticket"

  defp lane_part_via(%{relation: "blocks", identifier: identifier}), do: ", blocks #{identifier}"
  defp lane_part_via(%{relation: "sub_ticket_of", identifier: identifier}), do: ", sub-ticket of #{identifier}"
  defp lane_part_via(_via), do: ""

  defp filter_payload(%{error: _} = payload, _repo_filter), do: payload

  defp filter_payload(payload, nil), do: refresh_visible_counts(payload)

  defp filter_payload(payload, repo_filter) when is_binary(repo_filter) do
    payload
    |> Map.update(:running, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:watching, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:human_review, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:retrying, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:awaiting_clarification, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:skipped, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:run_history, [], &filter_repo_rows(&1, repo_filter))
    |> Map.update(:conflicts, [], &filter_conflict_rows(&1, repo_filter))
    |> refresh_visible_counts()
  end

  defp refresh_visible_counts(payload) do
    Map.put(payload, :counts, %{
      running: payload |> Map.get(:running, []) |> length(),
      watching: payload |> Map.get(:watching, []) |> length(),
      human_review: payload |> Map.get(:human_review, []) |> length(),
      conflicts: payload |> Map.get(:conflicts, []) |> length(),
      retrying: payload |> Map.get(:retrying, []) |> length()
    })
  end

  defp filter_repo_rows(rows, repo_filter), do: Enum.filter(rows, &(Map.get(&1, :repo_key) == repo_filter))

  defp filter_conflict_rows(rows, repo_filter) do
    Enum.filter(rows, fn entry -> repo_filter in conflict_repos(entry) end)
  end

  defp normalize_repo_filter(value, _payload) when value in [nil, "", "all"], do: nil

  defp normalize_repo_filter(value, payload) when is_binary(value) do
    if value in Map.get(payload, :repos, []), do: value, else: nil
  end

  defp normalize_repo_filter(_value, _payload), do: nil

  defp dashboard_filter_path(value) when value in [nil, "", "all"], do: "/"
  defp dashboard_filter_path(value), do: "/?" <> URI.encode_query(%{"repo" => value})

  defp repo_label(%{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp repo_label(_entry), do: nil

  defp repo_chip(assigns) do
    assigns = Map.put_new(assigns, :class, nil)

    ~H"""
    <span
      :if={@repo}
      class={["repo-chip", @class]}
      title={@repo}
      aria-label={"Repository #{@repo}"}
    >
      <span class="repo-chip-text"><%= @repo %></span>
    </span>
    """
  end

  defp forced_marker(assigns) do
    ~H"""
    <span :if={@forced} class="forced-marker" title="Forced" aria-label="Forced">⚡</span>
    """
  end

  defp forced_max(%{concurrency: %{forced_max: forced_max}}), do: forced_max
  defp forced_max(_payload), do: Config.settings!().agent.forced_max

  defp conflict_repos(%{repo_keys: repos}) when is_list(repos), do: repos
  defp conflict_repos(_entry), do: []

  defp reload_after_control(socket, result) do
    socket
    |> assign_payload(load_payload())
    |> disarm_control()
    |> assign(:control_error, control_error(result))
  end

  defp arm_control(socket, control) do
    token = make_ref()
    Process.send_after(self(), {:disarm_control, token}, control_confirm_timeout_ms())

    socket
    |> assign(:pending_control, control)
    |> assign(:pending_control_token, token)
  end

  defp disarm_control(socket) do
    socket
    |> assign(:pending_control, nil)
    |> assign(:pending_control_token, nil)
  end

  defp control_error({:ok, _payload}), do: nil
  defp control_error(:unavailable), do: "Orchestrator unavailable"
  defp control_error({:error, reason}), do: "Control failed: #{inspect(reason)}"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp stray_processes do
    Endpoint.config(:stray_processes) || SymphonyElixir.StrayProcesses
  end

  defp human_actions do
    Endpoint.config(:human_actions) || SymphonyElixir.HumanActions
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp control_confirm_timeout_ms do
    Application.get_env(:symphony_elixir, :dashboard_control_confirm_timeout_ms, @default_control_confirm_timeout_ms)
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_last_run(%{last_ran_at: last_ran_at}, now) do
    case seconds_since(last_ran_at, now) do
      seconds when is_integer(seconds) -> format_ago(seconds)
      _ -> "n/a"
    end
  end

  defp format_last_run(%{seconds_since_last_run: seconds}, _now) when is_integer(seconds) do
    format_ago(seconds)
  end

  defp format_last_run(_entry, _now), do: "n/a"

  defp seconds_since(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.diff(now, parsed, :second) |> max(0)
      _ -> nil
    end
  end

  defp seconds_since(_timestamp, _now), do: nil

  defp format_ago(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp format_ago(_seconds), do: "n/a"

  defp waiting_kind_label("plan"), do: "Plan"
  defp waiting_kind_label("pr"), do: "PR"
  defp waiting_kind_label("final_verification"), do: "Final verification"
  defp waiting_kind_label("action"), do: "Decision"

  defp github_webhooks(%{pollers: %{ci: %{webhooks: %{} = webhooks}}}), do: webhooks
  defp github_webhooks(_payload), do: nil

  defp format_event_at(nil, _now), do: nil

  defp format_event_at(timestamp, now) when is_binary(timestamp) do
    case seconds_since(timestamp, now) do
      seconds when is_integer(seconds) -> format_ago(seconds)
      _ -> String.slice(timestamp, 11, 8)
    end
  end

  defp format_event_at(_timestamp, _now), do: nil

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_budget_usage(used, limit) when is_integer(limit) and limit > 0 do
    "#{format_compact_int(used)} / #{format_compact_int(limit)}"
  end

  defp format_budget_usage(used, _limit), do: format_compact_int(used)

  defp format_budget_limit(limit) when is_integer(limit) and limit > 0, do: format_compact_int(limit)
  defp format_budget_limit(_limit), do: "Unlimited"

  defp issue_budget_limited?(limit), do: is_integer(limit) and limit > 0

  defp format_issue_budget_remaining(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    limit
    |> Kernel.-(max(used, 0))
    |> max(0)
    |> format_compact_int()
  end

  defp format_issue_budget_remaining(_used, _limit), do: "n/a"

  defp daily_budget_detail(%{daily_paused: true}), do: "paused"

  defp daily_budget_detail(%{daily_remaining: remaining}) when is_integer(remaining) do
    "#{format_compact_int(remaining)} left"
  end

  defp daily_budget_detail(_budget), do: "no limit"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp recent_runs(payload), do: payload |> Map.get(:run_history, []) |> Enum.take(@recent_runs_limit)

  # A model or effort that resolved to nothing adds no flag, so the runtime's own default applies.
  defp profile_value(nil), do: "default"
  defp profile_value(value), do: value

  defp format_compact_int(value) when is_integer(value) do
    abs_value = abs(value)

    cond do
      abs_value >= 1_000_000_000 -> format_compact_number(value, 1_000_000_000, "B")
      abs_value >= 1_000_000 -> format_compact_number(value, 1_000_000, "M")
      abs_value >= 1_000 -> format_compact_number(value, 1_000, "K")
      true -> Integer.to_string(value)
    end
  end

  defp format_compact_int(_value), do: "n/a"

  defp blocker_label(%{kind: :manual}), do: "Manually paused"
  defp blocker_label(%{kind: :budget}), do: "Daily token budget exhausted"

  defp blocker_label(%{kind: :missing_api_key, provider: provider}),
    do: "Missing #{provider |> to_string() |> String.upcase()} API key"

  defp blocker_label(%{kind: :config_invalid}), do: "Config invalid"

  defp blocker_label(%{kind: :tracker_unavailable, tracker: tracker}),
    do: "#{tracker |> tracker_name() |> String.capitalize()} tracker unavailable"

  defp blocker_label(%{kind: :usage_limit} = blocker), do: UsageLimit.hold_label(blocker)

  defp blocker_detail(%{kind: :manual, reason: reason, since: since}) do
    [reason, since && "since #{since}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  defp blocker_detail(%{kind: :budget, used: used, limit: limit, resets_on: resets_on}) do
    "#{format_compact_int(used)} / #{format_compact_int(limit)} (resets #{resets_on})"
  end

  defp blocker_detail(%{kind: :usage_limit, resume_at: resume_at}), do: "resumes at #{resume_at}"

  defp blocker_detail(%{kind: :missing_api_key}),
    do: "set the env var and restart symphony"

  defp blocker_detail(%{
         kind: :config_invalid,
         message: message,
         since: since,
         consecutive_failures: consecutive_failures
       }) do
    [
      message,
      "#{format_compact_int(consecutive_failures)} consecutive failures",
      since && "since #{since}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  defp blocker_detail(%{
         kind: :tracker_unavailable,
         reason: reason,
         since: since,
         consecutive_failures: consecutive_failures
       }) do
    [
      tracker_unavailable_reason(reason),
      "#{format_compact_int(consecutive_failures)} consecutive failures",
      since && "since #{since}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  defp tracker_name(:linear), do: "linear"
  defp tracker_name("linear"), do: "linear"
  defp tracker_name(:memory), do: "memory"
  defp tracker_name("memory"), do: "memory"
  defp tracker_name(tracker) when is_atom(tracker), do: Atom.to_string(tracker)
  defp tracker_name(tracker) when is_binary(tracker), do: tracker
  defp tracker_name(_tracker), do: "unknown"

  defp tracker_unavailable_reason(:missing_linear_api_token), do: "invalid or missing API key"
  defp tracker_unavailable_reason(:linear_api_request), do: "Linear API request failed"
  defp tracker_unavailable_reason(_reason), do: "unknown tracker failure"

  defp format_compact_number(value, divisor, suffix) do
    value
    |> Kernel./(divisor)
    |> :erlang.float_to_binary(decimals: 1)
    |> trim_trailing_decimal_zero()
    |> Kernel.<>(suffix)
  end

  defp trim_trailing_decimal_zero(value) do
    String.replace_suffix(value, ".0", "")
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp format_optional_int(value) when is_integer(value), do: Integer.to_string(value)
  defp format_optional_int(_value), do: "n/a"

  defp quality_gate_badge_class(%{kind: "error"}), do: "state-badge state-badge-danger"
  defp quality_gate_badge_class(_entry), do: "state-badge state-badge-warning"

  defp quality_gate_kind_label(%{kind: "error"}), do: "Error"
  defp quality_gate_kind_label(%{kind: "scored"}), do: "Scored"
  defp quality_gate_kind_label(%{kind: kind}) when is_binary(kind), do: String.capitalize(kind)
  defp quality_gate_kind_label(_entry), do: "Skipped"

  defp quality_gate_detail(%{kind: "error", error: error}) when is_binary(error) and error != "", do: error
  defp quality_gate_detail(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp quality_gate_detail(_entry), do: "n/a"

  defp pending_stop?({:stop, issue_id}, issue_id), do: true
  defp pending_stop?(_pending_control, _issue_id), do: false

  defp transcript_path(entry) do
    URLUtils.transcript_path(Map.get(entry, :repo_key) || current_repo_key(), Map.get(entry, :issue_identifier)) || "#"
  end

  defp audit_path(entry) do
    params =
      [
        {"repo", Map.get(entry, :repo_key) || current_repo_key()},
        {"issue", Map.get(entry, :issue_identifier)},
        {"run_id", Map.get(entry, :run_id)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    "/audit?" <> URI.encode_query(params)
  end

  defp current_repo_key, do: Config.repo_key_or_nil()

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
