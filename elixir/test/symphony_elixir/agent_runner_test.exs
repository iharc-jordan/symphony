defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "managed runner invokes session and turn callbacks with attempt scoped updates" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-runner-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RUNNER")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-runner"},"model":"gpt-5.6-luna","reasoningEffort":null}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-runner"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-runner",
        identifier: "MT-RUNNER",
        title: "Managed runner",
        description: "Exercise runner lifecycle callbacks",
        state: "In Progress",
        url: "https://example.org/issues/MT-RUNNER",
        labels: ["backend"]
      }

      attempt = %{
        assignment_id: "issue-runner",
        revision: "rev-1",
        generation: 3,
        attempt_id: "attempt-runner"
      }

      parent = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 parent,
                 managed_attempt: attempt,
                 model: "gpt-5.6-luna",
                 effort: "xhigh",
                 max_turns: 1,
                 on_session: fn info ->
                   send(parent, {:on_session, info})
                   :ok
                 end,
                 before_turn: fn context ->
                   send(parent, {:before_turn, context})
                   :ok
                 end,
                 issue_state_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:worker_runtime_info, "issue-runner", %{attempt: ^attempt}}
      assert_receive {:on_session, %{thread_id: "thread-runner", model: "gpt-5.6-luna", effort: "xhigh"}}
      assert_receive {:before_turn, %{attempt: ^attempt, turn: 1, remaining_turns: 1, model: "gpt-5.6-luna", effort: "xhigh"}}
      assert_receive {:codex_worker_update, "issue-runner", %{attempt: ^attempt, event: :session_started}}
    after
      File.rm_rf(test_root)
    end
  end

  test "managed runner reports exhausted budget when the final turn leaves issue active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-runner-final-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FINAL-BUDGET")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-final-budget"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-final-budget"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-final-budget",
        identifier: "MT-FINAL-BUDGET",
        title: "Final budget",
        description: "Final turn leaves issue active",
        state: "In Progress",
        url: "https://example.org/issues/MT-FINAL-BUDGET",
        labels: []
      }

      attempt = %{
        assignment_id: "issue-final-budget",
        revision: "rev-1",
        generation: 0,
        attempt_id: "attempt-final-budget"
      }

      assert catch_exit(
               AgentRunner.run(issue, nil,
                 managed_attempt: attempt,
                 max_turns: 1,
                 issue_state_fetcher: fn [_id] -> {:ok, [issue]} end
               )
             ) == {:managed_agent_guard_stop, :turn_budget_exhausted}
    after
      File.rm_rf(test_root)
    end
  end

  test "managed runner rejects an exhausted turn allowance before launching AppServer" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-runner-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-BUDGET")
      codex_binary = Path.join(test_root, "fake-codex")
      marker = Path.join(test_root, "launched")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-budget",
        identifier: "MT-BUDGET",
        title: "Exhausted budget",
        description: "Do not launch when no turn remains",
        state: "In Progress",
        url: "https://example.org/issues/MT-BUDGET",
        labels: ["backend"]
      }

      attempt = %{
        assignment_id: "issue-budget",
        revision: "rev-1",
        generation: 0,
        attempt_id: "attempt-budget"
      }

      assert catch_exit(
               AgentRunner.run(issue, nil,
                 managed_attempt: attempt,
                 max_turns: 0,
                 remaining_turns: 0
               )
             ) == {:managed_agent_guard_stop, :turn_budget_exhausted}

      refute File.exists?(marker)
    after
      File.rm_rf(test_root)
    end
  end
end
