defmodule SymphonyElixir.Managed.CheckoutTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Checkout
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-checkout-test-#{System.unique_integer([:positive, :monotonic])}")
    workspaces = Path.join(root, "worker workspaces")
    workspace = Path.join(workspaces, "assigned checkout")
    control = Path.join(root, "private control")
    helper = Path.join(root, "helper's script.py")
    policy = Path.join(root, "checkout policy.json")
    File.mkdir_p!(workspace)
    File.mkdir_p!(control)
    File.write!(policy, Jason.encode!(%{control_root: control, workspace_root: workspaces}))

    File.write!(helper, """
    import json, os, pathlib, sys
    assert sys.argv[1] == 'checkout'
    assert sys.argv[2] == '--input'
    assert sys.argv[4] == '--policy'
    payload = {'input': json.loads(pathlib.Path(sys.argv[3]).read_text()),
               'context': json.loads(os.environ['SYMPHONY_ISSUE_CONTEXT']),
               'argv': sys.argv[1:], 'helper': sys.argv[0], 'executable': sys.executable}
    pathlib.Path('helper-proof.json').write_text(json.dumps(payload))
    """)

    issue = %Issue{
      id: "project-item-1",
      identifier: "example/repository#2; this is identity text",
      title: "Private title must not become hook input",
      description: "Private issue requirements stay in the tracker",
      native_ref: %{"issue_id" => "issue-node-1", "repository" => %{"name_with_owner" => "example/repository"}}
    }

    assignment = %{assignment_id: issue.id, repository: "example/repository", base_commit: String.duplicate("a", 40), revision: 1}
    attempt = %{assignment_id: issue.id, attempt_id: "attempt / ' 1", revision: 1, generation: 1}
    opts = [node_executable: System.find_executable("python3"), helper_path: helper, policy_file: policy]
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      root: root,
      control: control,
      workspace: workspace,
      workspaces: workspaces,
      helper: helper,
      policy: policy,
      issue: issue,
      assignment: assignment,
      attempt: attempt,
      opts: opts
    }

    {:ok, context}
  end

  test "invokes the helper with argv and bounded context; keeps immutable private input", c do
    assert :ok = prepare(c)
    [input_file] = Path.wildcard(Path.join(c.control, "attempts/*.json"))
    before = File.read!(input_file)
    assert Bitwise.band(File.stat!(input_file).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(input_file)).mode, 0o777) == 0o700
    proof = c.workspace |> Path.join("helper-proof.json") |> File.read!() |> Jason.decode!()
    assert proof["input"]["workspace"] == c.workspace
    assert proof["input"]["attempt_id"] == c.attempt.attempt_id
    assert proof["input"]["base_commit"] == c.assignment.base_commit
    assert proof["argv"] == ["checkout", "--input", input_file, "--policy", c.policy]
    assert proof["context"]["identifier"] == c.issue.identifier
    refute Map.has_key?(proof["context"], "description")
    refute Map.has_key?(proof["context"], "title")
    assert :ok = prepare(c)
    assert File.read!(input_file) == before
  end

  test "rejects stale or mismatched attempt identities before writing", c do
    assert {:error, :checkout_attempt_identity_invalid} = prepare(%{c | attempt: %{c.attempt | revision: 2}})
    assert {:error, :checkout_attempt_identity_invalid} = prepare(%{c | issue: %{c.issue | id: "other-item"}})
    refute File.exists?(Path.join(c.control, "attempts"))
  end

  test "invokes canonical trusted paths when configuration uses symlinks", c do
    helper_alias = Path.join(c.root, "helper alias")
    policy_alias = Path.join(c.root, "policy alias")
    node_alias = Path.join(c.root, "node alias")
    File.ln_s!(c.helper, helper_alias)
    File.ln_s!(c.policy, policy_alias)
    File.ln_s!(Keyword.fetch!(c.opts, :node_executable), node_alias)
    opts = [node_executable: node_alias, helper_path: helper_alias, policy_file: policy_alias]
    assert :ok = prepare(%{c | opts: opts})
    proof = c.workspace |> Path.join("helper-proof.json") |> File.read!() |> Jason.decode!()
    assert proof["helper"] == c.helper
    assert List.last(proof["argv"]) == c.policy
    refute proof["executable"] == node_alias
  end

  test "does not overwrite conflicting or symlinked attempt inputs", c do
    assert :ok = prepare(c)
    [input_file] = Path.wildcard(Path.join(c.control, "attempts/*.json"))
    File.write!(input_file, "{}")
    assert {:error, :checkout_input_conflict} = prepare(c)
    assert File.read!(input_file) == "{}"
    File.rm!(input_file)
    File.ln_s!(c.policy, input_file)
    assert {:error, :checkout_input_conflict} = prepare(c)
  end

  test "rejects checkout escapes and control roots inside worker workspaces", c do
    assert {:error, :checkout_path_boundary_invalid} = prepare(%{c | workspace: c.root})
    outside = Path.join(c.root, "outside")
    File.mkdir_p!(outside)
    escape = Path.join(c.workspaces, "escape")
    File.ln_s!(outside, escape)
    assert {:error, :checkout_path_boundary_invalid} = prepare(%{c | workspace: escape})
    File.write!(c.policy, Jason.encode!(%{control_root: c.workspace, workspace_root: c.workspaces}))
    assert {:error, :checkout_path_boundary_invalid} = prepare(c)
    refute File.exists?(Path.join(c.workspace, "attempts"))
  end

  test "keeps failed preparation input and does not return helper output", c do
    File.write!(c.helper, "import sys; print('private helper diagnostic'); sys.exit(7)\n")
    assert {:error, {:checkout_helper_failed, 7}} = prepare(c)
    assert [_input_file] = Path.wildcard(Path.join(c.control, "attempts/*.json"))
  end

  test "a missing runtime executable fails without losing the attempt input", c do
    opts = Keyword.put(c.opts, :node_executable, Path.join(c.root, "missing-node"))
    assert {:error, {:managed_checkout_failed, ErlangError}} = prepare(%{c | opts: opts})
    assert [_input_file] = Path.wildcard(Path.join(c.control, "attempts/*.json"))
  end

  test "rejects missing config and invalid or oversized policy", c do
    assert {:error, {:checkout_configuration_missing, :node_executable}} = prepare(%{c | opts: []})
    assert {:error, {:checkout_absolute_path_required, :node_executable}} = prepare(%{c | opts: Keyword.put(c.opts, :node_executable, "python3")})
    File.write!(c.policy, "not json")
    assert {:error, :checkout_policy_invalid} = prepare(c)
    File.write!(c.policy, String.duplicate(" ", 16_385))
    assert {:error, :checkout_policy_invalid} = prepare(c)
  end

  defp prepare(c), do: Checkout.prepare(c.workspace, c.issue, c.assignment, c.attempt, c.opts)
end
