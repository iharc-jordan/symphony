defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Read-only, live ownership map and separate assignment history.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @terminal_phases ["accepted", "cancelled"]

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:view, normalized_view(params["view"]))
      |> assign(:display_mode, "map")
      |> assign(:query, "")
      |> assign(:selected_pm, if(normalized_view(params["view"]) == "live", do: params["pm"]))
      |> assign(:context_pm, params["pm"])
      |> assign(:retained_pm_ids, Enum.reject([params["pm"]], &is_nil/1))
      |> assign(:selected_task_id, nil)
      |> refresh_view()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = normalized_view(params["view"])
    context_pm = params["pm"] || socket.assigns.context_pm
    selected_pm = if view == "live", do: context_pm, else: history_selection(socket, view)

    socket =
      socket
      |> assign(:view, view)
      |> assign(:context_pm, context_pm)
      |> assign(:selected_pm, selected_pm)
      |> assign(:query, "")
      |> assign(:selected_task_id, nil)
      |> refresh_view()

    if (socket.assigns.view == "live" and socket.assigns.selected_pm) && params["pm"] != socket.assigns.selected_pm do
      {:noreply, push_patch(socket, to: dashboard_path(view, socket.assigns.selected_pm), replace: true)}
    else
      {:noreply, socket}
    end
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
     |> assign(:now, DateTime.utc_now())
     |> refresh_view()}
  end

  @impl true
  def handle_event("show_view", %{"view" => view}, socket) when view in ["live", "history", "runtime"] do
    {:noreply, push_patch(socket, to: dashboard_path(view, socket.assigns.context_pm), replace: true)}
  end

  def handle_event("set_layout", %{"layout" => layout}, socket) when layout in ["map", "list"] do
    {:noreply, assign(socket, :display_mode, layout)}
  end

  def handle_event("select_pm", %{"id" => id}, socket) do
    socket = socket |> assign(:selected_pm, id) |> assign(:selected_task_id, nil) |> refresh_view()

    if socket.assigns.view == "live" and socket.assigns.selected_pm do
      {:noreply, push_patch(socket, to: dashboard_path("live", socket.assigns.selected_pm), replace: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_task", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_task_id, id) |> refresh_view()}
  end

  def handle_event("show_pm", _params, socket) do
    {:noreply, assign(socket, :selected_task_id, nil) |> refresh_view()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, String.slice(query, 0, 200)) |> refresh_view()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard-shell">
      <header class="app-header">
        <a class="brand" href="/" aria-label="Symphony home">
          <svg viewBox="0 0 32 32" aria-hidden="true"><path d="M8 16h9m0 0 7-8m-7 8 7 8"/><circle cx="7" cy="16" r="4"/><circle cx="25" cy="7" r="3"/><circle cx="25" cy="25" r="3"/></svg>
          <span>Symphony</span>
        </a>
        <span class="app-description">Your orchestration workspace</span>
        <div class="connection-status" aria-live="polite">
          <span class="status-badge-live"><i></i>Live updates</span>
          <span class="status-badge-offline"><i></i>Disconnected</span>
        </div>
      </header>

      <div class="page-heading">
        <div>
          <h1>{view_title(@view)}</h1>
          <p>{view_description(@view)}</p>
        </div>
        <span class="updated-at">Updated {updated_time(@payload)}</span>
      </div>

      <nav class="workspace-tabs" aria-label="Workspace views">
        <button type="button" phx-click="show_view" phx-value-view="live" aria-current={if @view == "live", do: "page"} class={if @view == "live", do: "is-current"}>
          <.small_icon name="map" />Live work<span>{@open_count}</span>
        </button>
        <button type="button" phx-click="show_view" phx-value-view="history" aria-current={if @view == "history", do: "page"} class={if @view == "history", do: "is-current"}>
          <.small_icon name="history" />History<span>{@history_count}</span>
        </button>
        <button type="button" phx-click="show_view" phx-value-view="runtime" aria-current={if @view == "runtime", do: "page"} class={if @view == "runtime", do: "is-current"}>
          <.small_icon name="activity" />Runtime
        </button>
      </nav>

      <%= if @payload[:error] do %>
        <section class="snapshot-error" role="status">
          <h2>Snapshot unavailable</h2>
          <p>{@payload.error.message}</p>
          <code>{@payload.error.code}</code>
        </section>
      <% else %>
        <%= if @view == "runtime" or is_nil(@payload[:managed]) do %>
          <.runtime_panel payload={@payload} now={@now} />
        <% else %>
          <div :if={@payload.managed.dispatch_paused} class="dispatch-notice">
            <.small_icon name="pause" /><strong>New dispatch is paused.</strong>
            <span>Existing worker activity is shown below.</span>
          </div>

          <div :if={@view == "live"} class="work-summary" aria-label="Current work counts">
            <span><i class="state-dot state-running"></i><strong>{@work_counts.running}</strong> running</span>
            <span><i class="state-dot state-review"></i><strong>{@work_counts.review}</strong> need review</span>
            <span><i class="state-dot state-waiting"></i><strong>{@work_counts.waiting}</strong> waiting</span>
            <span><i class="state-dot state-ready"></i><strong>{@work_counts.queued}</strong> queued</span>
            <span class="summary-usage"><strong>{format_tokens(@payload.managed.usage, :inflight_tokens)}</strong> current-attempt tokens</span>
            <span><strong>{format_duration(running_seconds(@payload, @now))}</strong> running-worker time</span>
          </div>

          <div class="workspace">
            <aside class="manager-sidebar" aria-label="Project managers">
              <div class="sidebar-heading"><h2>Project managers</h2><span>{length(@groups)}</span></div>
              <p class="sidebar-caption">{if @view == "live", do: "Owners of current work", else: "Owners of historical work"}</p>
              <nav class="manager-list" aria-label="Choose a project manager">
                <button :for={group <- @groups} type="button" phx-click="select_pm" phx-value-id={group.id} aria-pressed={@selected_pm == group.id} class={["manager-option", @selected_pm == group.id && "is-selected"]}>
                  <span class={["manager-avatar", group.id == "__unassigned__" && "unassigned-avatar"]}>{if group.id == "__unassigned__", do: "?", else: "PM"}</span>
                  <span class="manager-option-copy">
                    <strong>{group.name}</strong>
                    <span>{group_counts_label(group, @view)}</span>
                  </span>
                  <span :if={group.running > 0} class="manager-running" title={"#{group.running} running workers"}>{group.running}</span>
                </button>
              </nav>
              <p :if={@groups == []} class="sidebar-empty">No matching work.</p>
              <div class="sidebar-note">
                <.small_icon name="link" />
                <p>Connections show responsibility. A moving connection means the worker is running.</p>
              </div>
            </aside>

            <section class="work-area" aria-label={view_title(@view)}>
              <div class="work-toolbar">
                <div class="work-toolbar-heading">
                  <h2>{if @selected_group, do: @selected_group.name, else: empty_heading(@view, @query)}</h2>
                  <p :if={@selected_group}>{group_counts_label(@selected_group, @view)} · {if @view == "live", do: "PM work", else: "earlier PM work"}</p>
                </div>
                <form phx-change="search" phx-submit="search" role="search" class="work-search">
                  <label class="sr-only" for="work-query">Find a task or PM</label>
                  <.small_icon name="search" /><input id="work-query" type="search" name="query" value={@query} placeholder="Find a task or PM" phx-debounce="200" />
                </form>
              </div>

              <%= if @selected_group do %>
                <div :if={@view == "live"} class="map-options">
                  <div class="layout-switch" aria-label="Display">
                    <button type="button" phx-click="set_layout" phx-value-layout="map" aria-pressed={@display_mode == "map"}><.small_icon name="map" />Map</button>
                    <button type="button" phx-click="set_layout" phx-value-layout="list" aria-pressed={@display_mode == "list"}><.small_icon name="list" />List</button>
                  </div>
                  <span>Select a node to see its details</span>
                </div>

                <div class={["work-content", @selected_task && "has-selection"]}>
                  <div class="work-visual">
                    <%= if @view == "live" and @display_mode == "map" do %>
                      <div class="map-viewport" tabindex="0" aria-label="PM and assignment ownership map">
                        <div class="mind-map" style={"height: #{@map_height}px"} id="ownership-map">
                          <svg class="map-connections" viewBox={"0 0 820 #{@map_height}"} preserveAspectRatio="none" aria-hidden="true">
                            <path :for={{task, index} <- Enum.with_index(@selected_group.tasks)} d={connection_path(index, @map_height)} class={["map-connection", worker_running?(task) && "connection-running", "connection-#{task.phase}"]} />
                            <circle cx="295" cy={div(@map_height, 2)} r="4" class="connection-origin" />
                          </svg>
                          <button type="button" phx-click="show_pm" class={["mind-node pm-node", is_nil(@selected_task) && "node-selected"]} style={"top: #{div(@map_height, 2) - 76}px"} aria-pressed={is_nil(@selected_task)}>
                            <span class="node-role"><span class="pm-symbol">{if @selected_group.id == "__unassigned__", do: "?", else: "PM"}</span>{if @selected_group.id == "__unassigned__", do: "Ownership needed", else: "Project manager"}</span>
                            <strong class="pm-node-title">{@selected_group.name}</strong>
                            <span class="pm-node-count">{group_counts_label(@selected_group, @view)}</span>
                            <span class="node-connector"></span>
                          </button>
                          <div class="map-tasks">
                            <button :for={{task, index} <- Enum.with_index(@selected_group.tasks)} type="button" phx-click="select_task" phx-value-id={task.assignment_id} data-assignment-id={task.assignment_id} aria-pressed={@selected_task_id == task.assignment_id} class={["mind-node task-node", "task-#{task.phase}", worker_running?(task) && "worker-running", @selected_task_id == task.assignment_id && "node-selected"]} style={"top: #{task_top(index)}px"}>
                              <span class="task-node-top"><span>{issue_label(task)}</span><span class={["task-state", "state-#{task.phase}"]}><i class={["state-dot", worker_running?(task) && "is-running"]}></i>{phase_label(task.phase)}</span></span>
                              <strong class="task-node-title">{task_label(task)}</strong>
                              <span class="task-node-meta">{route_label(task)}<span :if={worker_running?(task)} class="worker-label">Worker running</span></span>
                              <.task_metrics task={task} payload={@payload} now={@now} />
                              <span class="task-node-activity">{task_activity(task, @payload)}</span>
                            </button>
                          </div>
                        </div>
                      </div>
                      <div class="map-legend"><span><i class="legend-line"></i>Owns this task</span><span><i class="state-dot state-running"></i>Running worker</span><span><i class="state-dot state-review"></i>PM review</span><span><i class="state-dot state-waiting"></i>Waiting</span></div>
                    <% else %>
                      <div class="assignment-list" id={if @view == "history", do: "history-list", else: "live-list"}>
                        <button :for={task <- @selected_group.tasks} type="button" phx-click="select_task" phx-value-id={task.assignment_id} aria-pressed={@selected_task_id == task.assignment_id} data-assignment-id={task.assignment_id} class={["assignment-row", @selected_task_id == task.assignment_id && "is-selected"]}>
                          <span class={["row-state-mark", "state-#{task.phase}"]}></span>
                          <span class="assignment-row-copy"><strong>{task_label(task)}</strong><span>{task[:repository] || "Repository unavailable"} · {issue_label(task)}</span><.task_metrics task={task} payload={@payload} now={@now} /></span>
                          <span class={["task-state", "state-#{task.phase}"]}>{phase_label(task.phase)}</span>
                          <span class="row-chevron" aria-hidden="true">›</span>
                        </button>
                      </div>
                    <% end %>
                  </div>
                  <aside class="detail-panel" aria-label="Selection details" aria-live="polite">
                    <%= if @selected_task do %>
                      <div class="detail-heading"><span>Assignment details</span><button type="button" phx-click="show_pm" aria-label="Close assignment details">×</button></div>
                      <span class={["task-state", "state-#{@selected_task.phase}"]}>{phase_label(@selected_task.phase)}</span>
                      <h3>{@selected_task |> task_label()}</h3>
                      <dl class="detail-facts">
                        <div><dt>Responsible PM</dt><dd>{@selected_group.name}</dd></div>
                        <div><dt>Worker</dt><dd>{if worker_running?(@selected_task), do: "Running", else: "Not running"}</dd></div>
                        <div><dt>Runtime</dt><dd>{format_task_runtime(@selected_task, @payload, @now)}</dd></div>
                        <div :if={worker_running?(@selected_task)}><dt>Current run</dt><dd>{format_duration(current_run_seconds(@selected_task, @payload, @now))}</dd></div>
                        <div><dt>Total tokens</dt><dd>{format_tokens(@selected_task.usage, :total_tokens)}</dd></div>
                        <div><dt>Input tokens</dt><dd>{format_tokens(@selected_task.usage, :input_tokens)}</dd></div>
                        <div :if={@selected_task.usage[:cached_input_tokens]}><dt>Cached input tokens</dt><dd>{format_tokens(@selected_task.usage, :cached_input_tokens)}</dd></div>
                        <div><dt>Output tokens</dt><dd>{format_tokens(@selected_task.usage, :output_tokens)}</dd></div>
                        <div :if={@selected_task.worker.host}><dt>Worker host</dt><dd>{@selected_task.worker.host}</dd></div>
                        <div><dt>{if @selected_task.route[:source] == "running", do: "Running model & effort", else: "Configured model & effort"}</dt><dd>{route_label(@selected_task)}</dd></div>
                        <div><dt>Repository</dt><dd>{@selected_task[:repository] || "Not recorded"}</dd></div>
                      </dl>
                      <p :if={@selected_task[:blocked_reason]} class="waiting-reason"><strong>Waiting reason</strong>{@selected_task.blocked_reason}</p>
                      <p :if={@selected_task.projection.status == "failed"} class="waiting-reason"><strong>Project update failed</strong>{@selected_task.projection.error}</p>
                      <p :if={@selected_task[:stop_pending] == true} class="detail-note">Process reconciliation is pending.</p>
                      <%= if get_in(@selected_task, [:last_report, :summary]) do %>
                        <section class="report-preview"><h4>Latest report</h4><p>{@selected_task.last_report[:summary]}</p>
                          <details :if={@selected_task.last_report[:evidence] not in [nil, []]}><summary>Evidence</summary><ul><li :for={item <- @selected_task.last_report.evidence}>{item}</li></ul></details>
                        </section>
                      <% end %>
                      <details :if={@selected_task[:reports] not in [nil, [], %{}]} class="technical-details"><summary>Report history</summary><ul>
                        <li :for={report <- @selected_task.reports}><strong>{report[:kind] || "Report"}</strong><span :if={report[:report_id]}> · {report.report_id}</span><span :if={report[:summary]}> · {report.summary}</span></li>
                      </ul></details>
                      <details :if={@selected_task[:peer_report_refs] not in [nil, []]} class="technical-details"><summary>Peer report references</summary><ul>
                        <li :for={reference <- @selected_task.peer_report_refs}><code>{reference[:source_assignment_id] || "assignment unavailable"}</code> / <code>{reference[:source_attempt_id] || "attempt unavailable"}</code> / <code>{reference[:report_id] || "report unavailable"}</code></li>
                      </ul></details>
                      <.issue_identifier identifier={issue_label(@selected_task)} url={@selected_task[:issue_url]} />
                      <details class="technical-details"><summary>Task identifiers</summary><dl>
                        <div><dt>Assignment</dt><dd><code>{@selected_task.assignment_id}</code></dd></div>
                        <div :if={@selected_task.thread.id}><dt>Worker task</dt><dd><code>{@selected_task.thread.id}</code><.copy_id value={@selected_task.thread.id} /></dd></div>
                      </dl></details>
                    <% else %>
                      <div class="detail-heading"><span>{if @view == "live", do: "Ownership overview", else: "History overview"}</span></div>
                      <span class="detail-pm-avatar">{if @selected_group.id == "__unassigned__", do: "?", else: "PM"}</span>
                      <h3>{@selected_group.name}</h3>
                      <p class="detail-copy">{owner_description(@selected_group, @view)}</p>
                      <div class="owner-breakdown">
                        <div :for={{phase, count} <- phase_breakdown(@selected_group.tasks)}><span><i class={["state-dot", "state-#{phase}"]}></i>{phase_label(phase)}</span><strong>{count}</strong></div>
                      </div>
                      <p class="detail-note">PM identity shows ownership, not whether its Codex task is currently running.</p>
                      <p class="detail-note">Parent delivery is unverified. Counts describe assignment states.</p>
                      <details :if={@selected_group.id != "__unassigned__"} class="technical-details"><summary>PM task identifier</summary><code>{@selected_group.id}</code><.copy_id value={@selected_group.id} /></details>
                    <% end %>
                  </aside>
                </div>
              <% else %>
                <div class="workspace-empty">
                  <.small_icon name={if @view == "history", do: "history", else: "map"} />
                  <h3>{empty_heading(@view, @query)}</h3>
                  <p>{empty_description(@view, @query)}</p>
                </div>
              <% end %>
            </section>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)

  defp runtime_panel(assigns) do
    ~H"""
    <section class="runtime-panel">
      <div class="runtime-heading"><h2>Runtime details</h2><p>Session activity and service diagnostics.</p></div>
      <dl class="service-totals" aria-label="Service totals including completed sessions">
        <%= if @payload[:managed] do %>
          <div><dt>Managed tokens</dt><dd>{format_tokens(@payload.managed.usage, :cumulative_tokens)}</dd></div>
          <div><dt>Current-attempt tokens</dt><dd>{format_tokens(@payload.managed.usage, :inflight_tokens)}</dd></div>
        <% else %>
          <div><dt>Total tokens</dt><dd>{format_count(@payload.codex_totals.total_tokens)}</dd></div>
          <div><dt>Input tokens</dt><dd>{format_count(@payload.codex_totals.input_tokens)}</dd></div>
          <div><dt>Output tokens</dt><dd>{format_count(@payload.codex_totals.output_tokens)}</dd></div>
        <% end %>
        <div><dt>Total runtime</dt><dd>{format_duration((@payload.codex_totals.seconds_running || 0) + running_seconds(@payload, @now))}</dd></div>
      </dl>
      <%= if @payload[:managed] && @payload.managed[:diagnostics] do %>
        <section class="runtime-section"><h3>Concurrency limits</h3>
          <p class="detail-note">Effective global limit: <strong>{format_count(get_in(@payload, [:managed, :diagnostics, :concurrency, :global]))}</strong></p>
          <p class="detail-note">Per-state overrides: <code>{format_limits(get_in(@payload, [:managed, :diagnostics, :concurrency, :by_state]))}</code></p>
        </section>
      <% end %>
      <p class="detail-note">Service totals include completed sessions. Unavailable totals indicate incomplete historical accounting.</p>
      <section class="runtime-section"><h3>Running sessions <span>{length(@payload.running)}</span></h3>
        <p :if={@payload.running == []} class="empty-copy">No workers are running.</p>
        <article :for={entry <- @payload.running} class="session-row">
          <div><.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /><span>{entry.state}</span></div>
          <p class="session-message">{entry.last_message || to_string(entry.last_event || "No update yet")}</p>
          <div class="session-meta"><span>Runtime {format_runtime(entry.started_at, @now)} · {entry.turn_count} turns</span><span>Codex update {entry.last_event_at || "unavailable"}</span><.copy_id :if={entry.session_id} value={entry.session_id} /></div>
          <div class="session-meta"><span>Raw thread tokens {format_count(entry.tokens.total_tokens)}</span><span>Input {format_count(entry.tokens.input_tokens)} · Output {format_count(entry.tokens.output_tokens)}</span></div>
        </article>
      </section>
      <section class="runtime-section"><h3>Blocked sessions <span>{length(@payload.blocked)}</span></h3>
        <p :if={@payload.blocked == []} class="empty-copy">No blocked sessions.</p>
        <article :for={entry <- @payload.blocked} class="session-row">
          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
          <p>{entry.last_message || to_string(entry.last_event || "")}</p><p class="waiting-reason">{entry.error}</p>
        </article>
      </section>
      <section class="runtime-section"><h3>Retry queue <span>{length(@payload.retrying)}</span></h3>
        <p :if={@payload.retrying == []} class="empty-copy">No retries queued.</p>
        <article :for={entry <- @payload.retrying} class="session-row">
          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /><p>Attempt {entry.attempt} · {entry.due_at || "Time unavailable"}</p><p>{entry.error}</p>
        </article>
      </section>
      <details class="runtime-section"><summary>Rate limits</summary><pre>{inspect(@payload.rate_limits, pretty: true)}</pre></details>
      <%= if @payload[:managed] do %>
        <details class="runtime-section"><summary>Projects and repositories</summary>
          <article :for={{id, project} <- Enum.sort(@payload.managed.projects)} class="session-row"><strong>Project {project[:project_number] || id}</strong><p>{Enum.join(project.repositories, ", ")}</p><code>{id}</code></article>
        </details>
        <details :if={@payload.managed.handoffs != []} class="runtime-section"><summary>Ownership transfer history</summary>
          <article :for={event <- @payload.managed.handoffs} class="session-row"><strong>{humanize(event.operation)}</strong><p>{event[:source_id] || "—"} → {event[:destination_id] || "—"}</p><p>{event[:reason]}</p></article>
        </details>
      <% end %>
    </section>
    """
  end

  attr(:task, :map, required: true)
  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)

  defp task_metrics(assigns) do
    ~H"""
    <span class="task-metrics">
      <span data-metric="runtime" title="Recorded assignment runtime plus the current worker run">Runtime <strong>{format_task_runtime(@task, @payload, @now)}</strong></span>
      <span data-metric="tokens">Tokens <strong>{format_tokens(@task.usage, :total_tokens)}</strong></span>
    </span>
    """
  end

  attr(:name, :string, required: true)

  defp small_icon(assigns) do
    ~H"""
    <svg class="small-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <%= case @name do %>
        <% "map" -> %><rect x="2" y="9" width="6" height="6" rx="1.5"/><rect x="16" y="2" width="6" height="6" rx="1.5"/><rect x="16" y="16" width="6" height="6" rx="1.5"/><path d="M8 12h4V5h4M12 12v7h4"/>
        <% "history" -> %><path d="M3 11a9 9 0 1 1 2 7M3 4v7h7M12 7v5l3 2"/>
        <% "activity" -> %><path d="M2 12h5l3-8 4 16 3-8h5"/>
        <% "search" -> %><circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>
        <% "pause" -> %><path d="M9 5v14M15 5v14"/>
        <% "list" -> %><path d="M8 5h13M8 12h13M8 19h13M3 5h.01M3 12h.01M3 19h.01"/>
        <% _ -> %><path d="m10 13 4-4m-6 6-2 2a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0m-1 12 5-5a4 4 0 0 0-6-6" transform="translate(3 1)"/>
      <% end %>
    </svg>
    """
  end

  attr(:identifier, :string, required: true)
  attr(:url, :any, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a class="issue-link" href={@href} target="_blank" rel="noopener noreferrer" aria-label={"Open #{@identifier} in the issue tracker"}>{@identifier}<span aria-hidden="true"> ↗</span></a>
    <% else %>
      <span class="issue-link">{@identifier}</span>
    <% end %>
    """
  end

  attr(:value, :string, required: true)

  defp copy_id(assigns) do
    ~H"""
    <button type="button" class="copy-button" data-copy={@value} onclick="navigator.clipboard.writeText(this.dataset.copy).then(() => { this.textContent = 'Copied'; setTimeout(() => { this.textContent = 'Copy ID' }, 1200); })">Copy ID</button>
    """
  end

  defp refresh_view(socket) do
    tasks = socket.assigns.payload |> get_in([:managed, :assignments]) |> assignment_values()
    {history, current} = Enum.split_with(tasks, &(&1.phase in @terminal_phases))
    open_pm_ids = current |> Enum.map(&owner_id/1) |> Enum.reject(&(&1 == "__unassigned__"))
    selected_live_pm = if socket.assigns.view == "live", do: socket.assigns.selected_pm
    retained = Enum.uniq(open_pm_ids ++ socket.assigns.retained_pm_ids ++ [selected_live_pm]) |> Enum.reject(&is_nil/1)
    {current_completed, history} = Enum.split_with(history, &(owner_id(&1) != "__unassigned__" and owner_id(&1) in retained))
    live_context = current ++ current_completed
    source = if socket.assigns.view == "history", do: history, else: live_context
    groups = source |> filter_tasks(socket.assigns.query) |> ownership_groups(socket.assigns.view)
    group = Enum.find(groups, &(&1.id == socket.assigns.selected_pm)) || List.first(groups)
    selected = find_selected_task(group, socket.assigns.selected_task_id)

    socket
    |> assign(:retained_pm_ids, retained)
    |> assign(:groups, groups)
    |> assign(:selected_group, group)
    |> assign(:selected_pm, group && group.id)
    |> assign(:context_pm, if(socket.assigns.view == "live" and group, do: group.id, else: socket.assigns.context_pm))
    |> assign(:selected_task, selected)
    |> assign(:selected_task_id, selected && selected.assignment_id)
    |> assign(:open_count, length(current))
    |> assign(:history_count, length(history))
    |> assign(:work_counts, work_counts(current))
    |> assign(:map_height, map_height(group))
  end

  defp find_selected_task(nil, _id), do: nil
  defp find_selected_task(group, id), do: Enum.find(group.tasks, &(&1.assignment_id == id))

  defp normalized_view(view) when view in ["history", "runtime"], do: view
  defp normalized_view(_view), do: "live"

  defp history_selection(socket, view), do: if(socket.assigns.view == view, do: socket.assigns.selected_pm)

  defp dashboard_path(view, pm) do
    params = if pm, do: %{"pm" => pm}, else: %{}
    params = if view == "live", do: params, else: Map.put(params, "view", view)
    if params == %{}, do: "/", else: "/?" <> URI.encode_query(params)
  end

  defp assignment_values(values) when is_map(values), do: Map.values(values)
  defp assignment_values(_values), do: []

  defp filter_tasks(tasks, query) do
    query = query |> String.trim() |> String.downcase()
    Enum.filter(tasks, &(search_text(&1) |> String.contains?(query)))
  end

  defp search_text(task) do
    [task[:title], task[:repository], task[:assignment_id], get_in(task, [:ownership, :display_name])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp ownership_groups(tasks, view) do
    tasks
    |> Enum.group_by(&owner_id/1)
    |> Enum.map(fn {id, values} ->
      %{
        id: id,
        name: group_name(id, values, view),
        tasks: Enum.sort_by(values, &task_sort/1),
        running: Enum.count(values, &worker_running?/1),
        open: Enum.count(values, &(&1.phase not in @terminal_phases)),
        accepted: Enum.count(values, &(&1.phase == "accepted")),
        cancelled: Enum.count(values, &(&1.phase == "cancelled"))
      }
    end)
    |> Enum.sort_by(&{&1.id == "__unassigned__", String.downcase(&1.name)})
  end

  defp group_counts_label(group, "history"), do: "#{length(group.tasks)} past #{plural(length(group.tasks), "task")}"

  defp group_counts_label(group, _view) do
    counts = "#{group.open} open · #{group.accepted} accepted"
    if group.cancelled > 0, do: counts <> " · #{group.cancelled} cancelled", else: counts
  end

  defp worker_running?(task), do: task.phase not in @terminal_phases and task.worker.active == true

  defp owner_id(%{ownership: %{status: "owned", pm_id: id}}) when is_binary(id), do: id
  defp owner_id(_task), do: "__unassigned__"

  defp group_name("__unassigned__", _tasks, "history"), do: "Earlier unassigned work"
  defp group_name("__unassigned__", _tasks, _view), do: "Needs a project manager"

  defp group_name(id, tasks, _view) do
    Enum.find_value(tasks, &get_in(&1, [:ownership, :display_name])) || "PM #{String.slice(id, 0, 8)}"
  end

  defp task_sort(task), do: {phase_order(task.phase), String.downcase(task_label(task)), task.assignment_id}
  defp phase_order("waiting"), do: 0
  defp phase_order("review"), do: 1
  defp phase_order("review_pending"), do: 1
  defp phase_order("active"), do: 2
  defp phase_order("ready"), do: 3
  defp phase_order(_phase), do: 4

  defp work_counts(tasks) do
    %{
      running: Enum.count(tasks, &(&1.worker.active == true)),
      review: Enum.count(tasks, &(&1.phase in ["review", "review_pending"])),
      waiting: Enum.count(tasks, &(&1.phase in ["waiting", "blocked", "failed"])),
      queued: Enum.count(tasks, &(&1.phase in ["ready", "bound", "queued"]))
    }
  end

  defp map_height(nil), do: 400
  defp map_height(group), do: max(length(group.tasks) * 200 + 28, 400)
  defp task_top(index), do: index * 200 + 26

  defp connection_path(index, height) do
    middle = div(height, 2)
    target = task_top(index) + 88
    "M 295 #{middle} C 367 #{middle}, 371 #{target}, 443 #{target}"
  end

  defp phase_breakdown(tasks) do
    tasks |> Enum.frequencies_by(& &1.phase) |> Enum.sort_by(fn {phase, _count} -> phase_order(phase) end)
  end

  defp phase_label("ready"), do: "Queued"
  defp phase_label("bound"), do: "Queued"
  defp phase_label("review"), do: "Needs review"
  defp phase_label("review_pending"), do: "Accepting"
  defp phase_label("active"), do: "Active"
  defp phase_label("accepted"), do: "Accepted"
  defp phase_label(phase), do: humanize(phase)

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp plural(1, word), do: word
  defp plural(_number, word), do: word <> "s"
  defp task_label(task), do: task[:title] || issue_label(task)
  defp issue_label(%{issue_number: number}) when is_integer(number), do: "Issue ##{number}"
  defp issue_label(task), do: "Task #{String.slice(task.assignment_id, 0, 10)}"

  defp route_label(task) do
    route = task[:route] || %{}
    model = route[:model] || "Model not recorded"
    short = model |> String.replace("gpt-5.6-", "") |> String.replace("gpt-", "") |> String.capitalize()
    if route[:effort], do: "#{short} · #{route.effort}", else: short
  end

  defp task_activity(%{phase: "accepted"}, _payload), do: "Accepted and retained in this PM's work"
  defp task_activity(%{phase: "cancelled"}, _payload), do: "Cancelled and retained for context"

  defp task_activity(%{worker: %{active: true}} = task, payload) do
    case Enum.find(payload.running, &(&1.issue_id == task.assignment_id)) do
      nil -> task.worker.activity || "Worker is running"
      active -> display_activity(active.last_message)
    end
  end

  defp task_activity(%{phase: phase}, _payload) when phase in ["review", "review_pending"], do: "With the PM for review"
  defp task_activity(%{phase: "waiting"} = task, _payload), do: task[:blocked_reason] || "Waiting for the next action"

  defp task_activity(%{phase: phase} = task, _payload) when phase in ["ready", "queued", "bound"] do
    case task[:wait_reason] do
      "concurrency_limit" -> "Waiting for a worker slot"
      "dependencies_not_accepted" -> "Waiting for dependency acceptance"
      "ready" -> "Ready for the scheduler"
      reason when is_binary(reason) -> humanize(reason)
      _ -> "Waiting to be dispatched"
    end
  end

  defp task_activity(_task, _payload), do: "Worker is not running"

  defp display_activity(nil), do: "Worker is running"

  defp display_activity(message) do
    message
    |> String.replace(~r/ \((?:rs_|msg_|call_|exec_)[^)]+\)/, "")
    |> String.replace(~r/^item (?:started|completed): /, "")
    |> String.capitalize()
  end

  defp owner_description(%{id: "__unassigned__"}, "live"), do: "These open assignments need an owner before work can proceed."
  defp owner_description(_group, "history"), do: "Earlier PM work, kept here for reference."
  defp owner_description(group, _view), do: "#{group.name} owns this work. Completed assignments stay connected so you can see the full task, including what is finished."

  defp view_title("history"), do: "Work history"
  defp view_title("runtime"), do: "Runtime"
  defp view_title(_view), do: "Live work"
  defp view_description("history"), do: "Completed work from earlier PMs, separate from the current PM's full task."
  defp view_description("runtime"), do: "A closer look at workers and service health."
  defp view_description(_view), do: "See who owns the work, what is running, and what needs attention."

  defp empty_heading(_view, query) when query != "", do: "No matching tasks"
  defp empty_heading("history", _query), do: "No past work yet"
  defp empty_heading(_view, _query), do: "No open assignments"
  defp empty_description(_view, query) when query != "", do: "Try a task title, repository, or PM name."
  defp empty_description("history", _query), do: "Completed and cancelled assignments will appear here."
  defp empty_description(_view, _query), do: "Completed work is in History. New assignments will appear here when they are enrolled."

  defp updated_time(%{generated_at: value}) when is_binary(value), do: String.slice(value, 11, 8) <> " UTC"
  defp updated_time(_payload), do: "unavailable"

  defp current_session(%{worker: %{active: true}, phase: phase} = task, payload) when phase not in @terminal_phases do
    Enum.find(payload.running, &(&1.issue_id == task.assignment_id))
  end

  defp current_session(_task, _payload), do: nil

  defp task_seconds(task, payload, now) do
    case current_session(task, payload) do
      nil -> task.usage[:seconds_running]
      session -> (task.usage[:seconds_running] || 0) + (elapsed_seconds(session.started_at, now) || 0)
    end
  end

  defp current_run_seconds(task, payload, now) do
    case current_session(task, payload) do
      nil -> nil
      session -> elapsed_seconds(session.started_at, now)
    end
  end

  defp format_task_runtime(task, payload, now) do
    duration = format_duration(task_seconds(task, payload, now))
    if task.usage[:runtime_complete] == false, do: duration <> " (partial history)", else: duration
  end

  defp format_tokens(%{accounting_status: status}, _key) when status in ["unavailable", "unreliable"], do: "Unavailable"

  defp format_tokens(%{telemetry_complete: false} = usage, key) do
    if is_number(usage[key]) and usage[key] > 0, do: format_count(usage[key]) <> " (partial)", else: "Incomplete telemetry"
  end

  defp format_tokens(usage, key), do: format_count(usage[key])

  defp running_seconds(payload, now), do: Enum.reduce(payload.running, 0, &((elapsed_seconds(&1.started_at, now) || 0) + &2))

  defp format_count(value) when is_number(value), do: value |> trunc() |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp format_count(_value), do: "Not recorded"

  defp format_limits(limits) when is_map(limits) and map_size(limits) > 0 do
    limits
    |> Enum.sort_by(fn {state, _limit} -> to_string(state) end)
    |> Enum.map_join(", ", fn {state, limit} -> "#{state}: #{format_count(limit)}" end)
  end

  defp format_limits(_limits), do: "none"

  defp format_runtime(started_at, now), do: format_duration(elapsed_seconds(started_at, now))

  defp format_duration(value) when is_number(value) do
    seconds = max(trunc(value), 0)
    minutes = div(rem(seconds, 3_600), 60)
    remainder = rem(seconds, 60)
    if seconds >= 3_600, do: "#{div(seconds, 3_600)}h #{minutes}m #{remainder}s", else: "#{minutes}m #{remainder}s"
  end

  defp format_duration(_value), do: "Not recorded"

  defp elapsed_seconds(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, started_at, _offset} -> max(DateTime.diff(now, started_at, :second), 0)
      _ -> nil
    end
  end

  defp elapsed_seconds(_value, _now), do: nil

  defp external_issue_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp load_payload do
    Presenter.state_payload(Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator, Endpoint.config(:snapshot_timeout_ms) || 15_000)
  end

  defp schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
end
