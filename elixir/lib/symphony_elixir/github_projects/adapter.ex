defmodule SymphonyElixir.GitHubProjects.Adapter do
  @moduledoc """
  GitHub Projects V2 tracker adapter.

  This adapter is intentionally read-only. Project status changes and repository
  enrollment are managed by the caller's workflow.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, :active),
         :ok <- validate_states(tracker_settings.terminal_states, :terminal) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids), do: client_module().fetch_issues_by_ids(ids)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings),
    do: client_module().secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_projects_client_module, Client)
  end

  defp validate_states(states, kind) when is_list(states) do
    if Enum.all?(states, &is_binary/1) do
      :ok
    else
      {:error, String.to_atom("invalid_github_projects_#{kind}_states")}
    end
  end

  defp validate_states(_states, :active), do: {:error, :missing_github_projects_active_states}
  defp validate_states(_states, :terminal), do: {:error, :missing_github_projects_terminal_states}
end
