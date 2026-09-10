defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
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
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>


        <%= if @payload[:managed] do %>
          <section class="section-card managed-summary">
            <div class="section-header">
              <div>
                <h2 class="section-title">Managed operations</h2>
                <p class="section-copy">Project ownership and worker state from the managed control plane.</p>
              </div>
              <span class={managed_status_class(@payload.managed.status)}>
                <%= humanize_status(@payload.managed.status) %>
              </span>
            </div>

            <p class={managed_dispatch_class(@payload.managed.dispatch_paused)}>
              Dispatch: <strong><%= if @payload.managed.dispatch_paused, do: "paused", else: "enabled" %></strong>
            </p>

            <div class="managed-count-grid">
              <%= for {label, key} <- [{"Running", :running}, {"Queued", :queued}, {"Review", :review}, {"Waiting", :waiting}, {"Blocked", :blocked}] do %>
                <article class="managed-count-card">
                  <p class="metric-label"><%= label %></p>
                  <p class="metric-value numeric"><%= @payload.managed.counts[key] %></p>
                </article>
              <% end %>
            </div>

            <%= if @payload.managed.projection.stale or @payload.managed.projection.errors != [] do %>
              <div class="projection-alert">
                <strong>Projection health: <%= humanize_status(@payload.managed.projection.status) %></strong>
                <%= if @payload.managed.projection.stale do %>
                  <span>Some managed state is stale.</span>
                <% end %>
                <%= for error <- @payload.managed.projection.errors do %>
                  <span><%= error.assignment_id %>: <%= error.error %></span>
                <% end %>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Projects and repositories</h2>
                <p class="section-copy">Bound project identities and their allowed repositories.</p>
              </div>
            </div>

            <%= if map_size(@payload.managed.projects) == 0 do %>
              <p class="empty-state">No managed projects are bound.</p>
            <% else %>
              <div class="managed-project-grid">
                <article :for={{project_id, project} <- managed_entries(@payload.managed.projects)} class="managed-project-card">
                  <h3><%= project_id %></h3>
                  <p class="muted">
                    Project #<%= Map.get(project, :project_number) || "n/a" %>
                    <%= if Map.get(project, :revision) do %> · revision <%= Map.get(project, :revision) %><% end %>
                  </p>
                  <p><strong>Repositories</strong></p>
                  <p class="mono"><%= join_values(project.repositories) %></p>
                </article>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Managed assignments</h2>
                <p class="section-copy">Who owns each task, where it is in the workflow, and whether its provider projection is current.</p>
              </div>
            </div>

            <%= if map_size(@payload.managed.assignments) == 0 do %>
              <p class="empty-state">No managed assignments are enrolled.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table managed-assignment-table">
                  <thead>
                    <tr>
                      <th>Task</th>
                      <th>Project / repository</th>
                      <th>Responsible PM</th>
                      <th>Work status</th>
                      <th>Worker</th>
                      <th>Projection</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{_assignment_id, assignment} <- managed_entries(@payload.managed.assignments)}>
                      <td>
                        <div class="issue-stack">
                          <%= if Map.get(assignment, :issue_url) do %>
                            <a class="issue-id" href={assignment.issue_url}><%= task_label(assignment) %></a>
                          <% else %>
                            <span class="issue-id"><%= task_label(assignment) %></span>
                          <% end %>
                          <span class="muted mono"><%= assignment.assignment_id %></span>
                        </div>
                      </td>
                      <td>
                        <span><%= Map.get(assignment, :project_id) || "n/a" %></span>
                        <span class="muted"><%= Map.get(assignment, :repository) || "repository unavailable" %></span>
                      </td>
                      <td>
                        <span class={owner_class(assignment)}><%= owner_label(assignment) %></span>
                        <%= if ownership_status_visible?(assignment) do %>
                          <span class="muted"><%= humanize_status(assignment.ownership.status) %></span>
                        <% end %>
                      </td>
                      <td><span class={managed_status_class(assignment.status)}><%= humanize_status(assignment.status) %></span></td>
                      <td>
                        <span class="mono"><%= worker_label(assignment) %></span>
                        <%= if assignment.worker.activity do %>
                          <span class="muted"><%= assignment.worker.activity %></span>
                        <% end %>
                      </td>
                      <td>
                        <span class={projection_status_class(assignment.projection)}>
                          <%= projection_label(assignment.projection) %>
                        </span>
                        <%= if assignment.projection.error do %>
                          <span class="muted"><%= assignment.projection.error %></span>
                        <% end %>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <%= if map_size(@payload.managed.principals) > 0 do %>
            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Responsible PMs</h2>
                  <p class="section-copy">Principal identities available to own managed tasks.</p>
                </div>
              </div>
              <div class="managed-principal-grid">
                <article :for={{principal_id, principal} <- managed_entries(@payload.managed.principals)} class="managed-principal-card">
                  <strong><%= principal.display_name %></strong>
                  <span class="muted mono"><%= principal_id %></span>
                  <span class="muted">Task link unavailable</span>
                </article>
              </div>
            </section>
          <% end %>

          <%= if @payload.managed.handoffs != [] do %>
            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Handoff history</h2>
                  <p class="section-copy">Recent ownership transfers and operator takeovers recorded by managed state.</p>
                </div>
              </div>
              <div class="handoff-list">
                <article :for={handoff <- @payload.managed.handoffs} class="handoff-entry">
                  <div>
                    <strong><%= humanize_status(handoff.operation) %></strong>
                    <span class="muted mono"><%= handoff.at || "time unavailable" %></span>
                  </div>
                  <p>
                    <span class="mono"><%= handoff.source_id || "source unavailable" %></span>
                    <span aria-hidden="true"> → </span>
                    <span class="mono"><%= handoff.destination_id || "destination unavailable" %></span>
                  </p>
                  <p class="muted"><%= handoff_reason(handoff) %></p>
                  <p class="muted">
                    <%= handoff_scope(handoff) %> · <%= handoff_outcome(handoff) %>
                  </p>
                </article>
              </div>
            </section>
          <% end %>
        <% end %>

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
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
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
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
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
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
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
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
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
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
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
      <% end %>
    </section>
    """
  end

  defp managed_entries(map) when is_map(map), do: Enum.sort_by(map, fn {id, _entry} -> to_string(id) end)
  defp managed_entries(_map), do: []

  defp humanize_status(nil), do: "Unavailable"

  defp humanize_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp managed_status_class(status) do
    normalized = status |> to_string() |> String.downcase()
    base = "state-badge"

    cond do
      normalized in ["available", "synced", "active", "owned", "enabled"] -> "#{base} state-badge-active"
      normalized in ["failed", "blocked", "error", "stale", "unknown", "unassigned"] -> "#{base} state-badge-danger"
      true -> "#{base} state-badge-warning"
    end
  end

  defp managed_dispatch_class(true), do: "managed-dispatch managed-dispatch-paused"
  defp managed_dispatch_class(false), do: "managed-dispatch managed-dispatch-enabled"

  defp projection_status_class(%{status: "synced", stale: false}), do: "state-badge state-badge-active"
  defp projection_status_class(%{status: "failed"}), do: "state-badge state-badge-danger"
  defp projection_status_class(%{status: status}) when status in ["pending", "stale"], do: "state-badge state-badge-warning"
  defp projection_status_class(_projection), do: "state-badge state-badge-danger"

  defp projection_label(%{status: status, stale: true}) when status == "synced", do: "Stale"
  defp projection_label(%{status: status}), do: humanize_status(status)
  defp projection_label(_projection), do: "Unknown"

  defp owner_class(assignment) do
    if assignment.ownership.status == "unassigned", do: "managed-owner managed-owner-missing", else: "managed-owner"
  end

  defp owner_label(assignment) do
    cond do
      assignment.ownership.status == "needs_claim" -> "Operator claim required"
      assignment.ownership.display_name -> assignment.ownership.display_name
      assignment.ownership.pm_id -> assignment.ownership.pm_id
      assignment.phase == "review" -> "Review owner unavailable"
      true -> "No PM owner"
    end
  end

  defp ownership_status_visible?(assignment) do
    assignment.ownership.status != "needs_claim"
  end

  defp task_label(assignment) do
    Map.get(assignment, :title) || assignment.task.id || repository_issue_label(assignment)
  end

  defp repository_issue_label(%{repository: repository, issue_number: number})
       when is_binary(repository) and is_integer(number) do
    "#{repository} ##{number}"
  end

  defp repository_issue_label(assignment) do
    assignment.assignment_id
  end

  defp worker_label(assignment) do
    cond do
      assignment.worker.id && assignment.worker.active == true -> assignment.worker.id <> " (active)"
      assignment.worker.id && assignment.worker.active == false -> assignment.worker.id <> " (down)"
      assignment.thread.id -> assignment.thread.id
      assignment.task.id -> assignment.task.id
      true -> "not running"
    end
  end

  defp handoff_reason(handoff) do
    cond do
      handoff.reason -> handoff.reason
      handoff.assignment_id -> "Assignment " <> handoff.assignment_id
      handoff.assignment_ids != [] -> "Assignments " <> Enum.join(handoff.assignment_ids, ", ")
      true -> "Assignment details unavailable"
    end
  end

  defp handoff_scope(%{assignment_ids: ids}) when is_list(ids) and ids != [] do
    "Assignments " <> Enum.join(ids, ", ")
  end

  defp handoff_scope(%{assignment_id: id}) when is_binary(id), do: "Assignment " <> id
  defp handoff_scope(_handoff), do: "Assignment scope unavailable"

  defp handoff_outcome(%{status: status}) when is_binary(status) and status != "" do
    "Outcome: " <> humanize_status(status)
  end

  defp handoff_outcome(_handoff), do: "Outcome unavailable"

  defp join_values(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp join_values(_values), do: "None recorded"

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

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

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
