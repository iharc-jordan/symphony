defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "managed runner requires successful workspace preparation before Codex" do
    issue = issue("preparer")
    attempt = attempt(issue)

    assert catch_exit(
             AgentRunner.run(issue, nil,
               managed_attempt: attempt,
               max_turns: 1
             )
           ) == {:managed_agent_failed, :missing_workspace_preparer}

    assert catch_exit(
             AgentRunner.run(issue, nil,
               managed_attempt: attempt,
               workspace_preparer: fn workspace ->
                 assert File.dir?(workspace)
                 {:error, :bootstrap_failed}
               end,
               max_turns: 1
             )
           ) == {:managed_agent_failed, {:workspace_preparer, :bootstrap_failed}}
  end

  test "managed runner rejects an exhausted allowance before starting Codex" do
    issue = issue("budget")
    attempt = attempt(issue)

    assert catch_exit(
             AgentRunner.run(issue, nil,
               managed_attempt: attempt,
               workspace_preparer: fn _workspace -> :ok end,
               max_turns: 0,
               remaining_turns: 0
             )
           ) == {:managed_agent_guard_stop, :turn_budget_exhausted}
  end

  defp issue(suffix) do
    %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-#{String.upcase(suffix)}",
      title: "Managed runner guard",
      description: "Validate pre-launch guard",
      state: "In Progress",
      url: "https://example.invalid/#{suffix}",
      dispatchable: true,
      labels: []
    }
  end

  defp attempt(issue) do
    %{assignment_id: issue.id, revision: "rev-1", generation: 0, attempt_id: "attempt-#{issue.id}"}
  end
end
