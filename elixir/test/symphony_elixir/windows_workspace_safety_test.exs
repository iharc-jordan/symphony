defmodule SymphonyElixir.WindowsWorkspaceSafetyTest do
  use SymphonyElixir.TestSupport

  @moduletag :windows

  setup do
    previous_helper = System.get_env("SYMPHONY_WINDOWS_WORKER_HOST")
    helper = Path.join([File.cwd!(), "native", "symphony_worker_host", "target", "debug", "symphony-worker-host.exe"])

    if File.regular?(helper) do
      System.put_env("SYMPHONY_WINDOWS_WORKER_HOST", helper)
    end

    on_exit(fn -> restore_env("SYMPHONY_WINDOWS_WORKER_HOST", previous_helper) end)
    :ok
  end

  test "uses opaque names below a native Unicode root and preserves an unowned sibling" do
    root = Path.join(System.tmp_dir!(), "symphony Windows workspace café #{System.unique_integer([:positive])}")
    sibling = Path.join(root, "unowned")

    try do
      File.mkdir_p!(sibling)
      File.write!(Path.join(sibling, "keep.txt"), "keep")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      assert {:ok, workspace} = Workspace.create_for_issue("PROJECT/été ?")
      assert Path.basename(workspace) =~ ~r/^w-[0-9a-f]{24}$/
      assert {:error, {:workspace_unowned, rejected_sibling}, ""} = Workspace.remove_recorded(sibling)
      assert SymphonyElixir.PathSafety.same_path?(rejected_sibling, sibling)
      assert File.read!(Path.join(sibling, "keep.txt")) == "keep"
      assert {:ok, _} = Workspace.remove(workspace)
    after
      File.rm_rf(root)
    end
  end

  test "rejects a junction at the derived workspace path before it can escape" do
    root = Path.join(System.tmp_dir!(), "symphony junction root #{System.unique_integer([:positive])}")
    outside = Path.join(System.tmp_dir!(), "symphony junction outside #{System.unique_integer([:positive])}")
    key = Workspace.workspace_key("JUNCTION-1")
    junction = Path.join(root, key)

    try do
      File.mkdir_p!(root)
      File.mkdir_p!(outside)

      script = "New-Item -ItemType Junction -Path $env:SYMPHONY_TEST_JUNCTION -Target $env:SYMPHONY_TEST_TARGET | Out-Null"

      assert {_output, 0} =
               System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script],
                 env: [{"SYMPHONY_TEST_JUNCTION", junction}, {"SYMPHONY_TEST_TARGET", outside}],
                 stderr_to_stdout: true
               )

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
      assert {:error, _reason} = Workspace.create_for_issue("JUNCTION-1")
      assert File.dir?(outside)
    after
      File.rm_rf(root)
      File.rm_rf(outside)
    end
  end

  test "concurrent creation shares one owned workspace without exposing an unowned gap" do
    root = Path.join(System.tmp_dir!(), "symphony concurrent workspace #{System.unique_integer([:positive])}")
    parent = self()
    identifier = "CONCURRENT-1"

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      tasks =
        for _ <- 1..24 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Workspace.create_for_issue(identifier)
            end
          end)
        end

      task_pids =
        for _ <- tasks do
          assert_receive {:ready, task_pid}, 1_000
          task_pid
        end

      Enum.each(task_pids, &send(&1, :go))
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert [{:ok, workspace}] = Enum.uniq(results)
      assert {:ok, ^workspace} = Workspace.validate_owned_workspace(workspace)
      assert {:ok, _removed} = Workspace.remove(workspace)
    after
      File.rm_rf(root)
    end
  end

  test "a timed out PowerShell hook cannot write into a recreated workspace" do
    root = Path.join(System.tmp_dir!(), "symphony hook timeout #{System.unique_integer([:positive])}")
    identifier = "HOOK-TIMEOUT"
    late_effect = "late-effect.txt"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        hook_timeout_ms: 50,
        hook_after_create: "Start-Sleep -Milliseconds 900; Set-Content -LiteralPath '#{late_effect}' -Value late"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 50}} = Workspace.create_for_issue(identifier)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
      assert {:ok, workspace} = Workspace.create_for_issue(identifier)
      Process.sleep(1_100)
      refute File.exists?(Path.join(workspace, late_effect))
    after
      File.rm_rf(root)
    end
  end
end
