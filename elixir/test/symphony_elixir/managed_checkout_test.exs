defmodule SymphonyElixir.Managed.CheckoutTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.Checkout

  test "prepares an owned workspace directly with Git at the pinned commit" do
    fixture = checkout_fixture!()
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: fixture.workspaces)
    {:ok, workspace} = Workspace.create_for_issue(fixture.issue.identifier)

    assert :ok =
             Checkout.prepare(
               workspace,
               fixture.issue,
               fixture.assignment,
               fixture.attempt,
               repository_url: fixture.remote,
               git_executable: fixture.git
             )

    assert git!(fixture.git, ["-C", workspace, "rev-parse", "HEAD"]) == fixture.base_commit
    assert normalized(git!(fixture.git, ["-C", workspace, "remote", "get-url", "origin"])) == normalized(fixture.remote)

    assert String.replace(File.read!(Path.join(workspace, "fixture.txt")), "\r\n", "\n") ==
             "direct checkout\n"
  end

  test "rejects stale attempt identity and preserves conflicting work" do
    fixture = checkout_fixture!()
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: fixture.workspaces)
    {:ok, workspace} = Workspace.create_for_issue(fixture.issue.identifier)

    assert {:error, :checkout_attempt_identity_invalid} =
             Checkout.prepare(
               workspace,
               fixture.issue,
               fixture.assignment,
               %{fixture.attempt | revision: 2},
               repository_url: fixture.remote,
               git_executable: fixture.git
             )

    File.write!(Path.join(workspace, "keep.txt"), "owned work\n")

    assert {:error, :checkout_workspace_conflict} =
             Checkout.prepare(
               workspace,
               fixture.issue,
               fixture.assignment,
               fixture.attempt,
               repository_url: fixture.remote,
               git_executable: fixture.git
             )

    assert File.read!(Path.join(workspace, "keep.txt")) == "owned work\n"
  end

  defp checkout_fixture! do
    root = Path.join(System.tmp_dir!(), "managed-checkout-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    remote = Path.join(root, "remote.git")
    workspaces = Path.join(root, "workspaces")
    git = System.find_executable("git") || raise "Git is required"

    File.mkdir_p!(source)
    git!(git, ["init", source])
    File.write!(Path.join(source, "fixture.txt"), "direct checkout\n")
    git!(git, ["-C", source, "add", "fixture.txt"])

    git!(git, [
      "-C",
      source,
      "-c",
      "user.email=fixture@example.test",
      "-c",
      "user.name=Checkout Fixture",
      "commit",
      "-m",
      "fixture"
    ])

    base_commit = git!(git, ["-C", source, "rev-parse", "HEAD"])
    git!(git, ["init", "--bare", remote])
    git!(git, ["-C", source, "remote", "add", "origin", remote])
    git!(git, ["-C", source, "push", "origin", "HEAD"])
    on_exit(fn -> File.rm_rf!(root) end)

    issue = %{id: "assignment-1", identifier: "acme/example#1"}

    assignment = %{
      assignment_id: issue.id,
      revision: 1,
      repository: "acme/example",
      base_commit: base_commit
    }

    attempt = %{assignment_id: issue.id, revision: 1, generation: 0, attempt_id: "attempt-1"}

    %{
      git: git,
      root: root,
      remote: remote,
      workspaces: workspaces,
      base_commit: base_commit,
      issue: issue,
      assignment: assignment,
      attempt: attempt
    }
  end

  defp git!(git, args) do
    case System.cmd(git, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end

  defp normalized(path), do: path |> String.replace("\\", "/") |> String.downcase()
end
