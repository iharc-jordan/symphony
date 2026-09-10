defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.Managed.{Control, Principal}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec managed_state(Conn.t(), map()) :: Conn.t()
  def managed_state(conn, _params) do
    with {:ok, principal} <- authorize_managed(conn),
         {:ok, payload} <- Control.state(orchestrator(), snapshot_timeout_ms()) do
      json(conn, Map.put(payload, :principal, principal))
    else
      {:error, :unauthorized} -> managed_error(conn, 401, "unauthorized", "Unauthorized")
      {:error, :forbidden} -> managed_error(conn, 403, "loopback_required", "Loopback access required")
      {:error, :managed_mode_disabled} -> managed_error(conn, 503, "managed_mode_disabled", "Managed mode is disabled")
      {:error, reason} -> managed_error(conn, 503, "managed_unavailable", safe_managed_message(reason))
    end
  end

  @spec managed_events(Conn.t(), map()) :: Conn.t()
  def managed_events(conn, params) do
    with {:ok, _principal} <- authorize_managed(conn),
         {:ok, after_cursor} <- bounded_integer(params["after"], 0, 0, :infinity),
         {:ok, limit} <- bounded_integer(params["limit"], 100, 1, 100),
         {:ok, wait_ms} <- bounded_integer(params["wait_ms"], 0, 0, 60_000),
         {:ok, events} <- wait_for_managed_events(after_cursor, limit, wait_ms) do
      json(conn, %{after: after_cursor, events: events, cursor: (List.last(events) && List.last(events).cursor) || after_cursor})
    else
      {:error, :unauthorized} -> managed_error(conn, 401, "unauthorized", "Unauthorized")
      {:error, :forbidden} -> managed_error(conn, 403, "loopback_required", "Loopback access required")
      {:error, :managed_mode_disabled} -> managed_error(conn, 503, "managed_mode_disabled", "Managed mode is disabled")
      {:error, reason} -> managed_error(conn, 400, "invalid_request", safe_managed_message(reason))
    end
  end

  @spec managed_control(Conn.t(), map()) :: Conn.t()
  def managed_control(conn, params) do
    with {:ok, principal} <- authorize_managed(conn),
         {:ok, response} <- Control.submit_authorized(orchestrator(), params, principal, snapshot_timeout_ms()) do
      conn |> put_status(200) |> json(response)
    else
      {:error, :unauthorized} ->
        managed_error(conn, 401, "unauthorized", "Unauthorized")

      {:error, :forbidden} ->
        managed_error(conn, 403, "loopback_required", "Loopback access required")

      {:error, :managed_mode_disabled} ->
        managed_error(conn, 503, "managed_mode_disabled", "Managed mode is disabled")

      {:error, code, details} when is_atom(code) ->
        managed_error(conn, 409, Atom.to_string(code), safe_managed_message(details), safe_managed_details(details))

      {:error, reason} ->
        managed_error(conn, 400, "invalid_request", safe_managed_message(reason))
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp authorize_managed(conn) do
    if loopback?(conn.remote_ip), do: authenticate_bearer(conn), else: {:error, :forbidden}
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp authenticate_bearer(conn) do
    expected = Config.managed_control_token()
    [header | _] = get_req_header(conn, "authorization") ++ [""]
    token = String.replace_prefix(header, "Bearer ", "")

    if String.starts_with?(header, "Bearer "),
      do: Principal.authenticate(token, expected),
      else: {:error, :unauthorized}
  end

  defp bounded_integer(nil, default, _minimum, _maximum), do: {:ok, default}

  defp bounded_integer(value, _default, minimum, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= minimum ->
        if within_max?(integer, maximum), do: {:ok, integer}, else: {:error, :invalid_integer}

      _ ->
        {:error, :invalid_integer}
    end
  end

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value) and value >= minimum do
    if within_max?(value, maximum), do: {:ok, value}, else: {:error, :invalid_integer}
  end

  defp bounded_integer(_value, _default, _minimum, _maximum), do: {:error, :invalid_integer}

  defp within_max?(_value, :infinity), do: true
  defp within_max?(value, maximum), do: value <= maximum

  defp wait_for_managed_events(after_cursor, limit, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    wait_for_managed_events(after_cursor, limit, deadline, wait_ms)
  end

  defp wait_for_managed_events(after_cursor, limit, deadline, _wait_ms) do
    case Control.events(orchestrator(), after_cursor, limit, 1_000) do
      {:ok, events} when events != [] ->
        {:ok, events}

      {:ok, []} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(50, remaining))
          wait_for_managed_events(after_cursor, limit, deadline, remaining)
        else
          {:ok, []}
        end

      other ->
        other
    end
  end

  defp managed_error(conn, status, code, message, details \\ %{}) do
    conn |> put_status(status) |> json(%{error: %{code: code, message: message, details: details}})
  end

  defp safe_managed_details(details) when is_map(details) do
    details
    |> Map.take([
      :assignment_id,
      :project_id,
      :current_pm_id,
      :pm_id,
      :owner_pm_id,
      :responsible_pm_id,
      :expected,
      :actual,
      :expected_revision,
      :actual_revision,
      :ownership_revision,
      :expected_ownership_revision,
      :argument
    ])
    |> Map.filter(fn {_key, value} -> is_binary(value) or is_number(value) or is_atom(value) end)
  end

  defp safe_managed_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_managed_message(%{argument: argument}) when is_atom(argument), do: "invalid argument: " <> Atom.to_string(argument)
  defp safe_managed_message(_reason), do: "Managed request failed"

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
