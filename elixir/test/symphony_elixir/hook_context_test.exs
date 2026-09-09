defmodule SymphonyElixir.HookContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HookContext

  test "encodes only identity and safe provider metadata" do
    issue = %{
      id: "project-item-42",
      identifier: "owner/repository#42",
      title: "private title",
      description: "private body",
      native_ref: %{
        project_id: "project-1",
        project_item_id: "item-42",
        issue_id: "issue-42",
        repository: %{
          "owner" => "owner",
          "name" => "repository",
          "name_with_owner" => "owner/repository",
          "id" => "repo-1",
          "url" => "https://example.test/owner/repository"
        },
        issue_number: 42,
        content_type: "Issue"
      }
    }

    assert {:ok, encoded} = HookContext.encode(issue)
    assert byte_size(encoded) <= HookContext.max_bytes()

    assert %{
             "id" => "project-item-42",
             "identifier" => "owner/repository#42",
             "native_ref" => %{
               "project_id" => "project-1",
               "project_item_id" => "item-42",
               "issue_id" => "issue-42",
               "repository" => %{
                 "owner" => "owner",
                 "name" => "repository",
                 "name_with_owner" => "owner/repository",
                 "id" => "repo-1",
                 "url" => "https://example.test/owner/repository"
               },
               "issue_number" => 42,
               "content_type" => "Issue"
             }
           } = Jason.decode!(encoded)

    refute encoded =~ "private title"
    refute encoded =~ "private body"
  end

  test "represents missing issue context with explicit null values" do
    assert {:ok, encoded} = HookContext.encode(nil)
    assert Jason.decode!(encoded) == %{"id" => nil, "identifier" => nil, "native_ref" => nil}

    assert {:ok, encoded} = HookContext.encode("MT-42")
    assert Jason.decode!(encoded) == %{"id" => nil, "identifier" => "MT-42", "native_ref" => nil}
  end

  test "rejects forbidden fields anywhere in an opaque native reference" do
    for key <- ["issue_body", "user_info", "access_token", "refresh_token", "private_key_file", "command"] do
      issue = %{id: "issue-1", identifier: "MT-1", native_ref: %{key => "sensitive"}}

      assert {:error, {:invalid_native_ref, {:forbidden_key, ^key}}} = HookContext.encode(issue)
    end
  end

  test "rejects non-json native reference values" do
    issue = %{id: "issue-1", identifier: "MT-1", native_ref: %{"ref" => self()}}
    assert {:error, {:invalid_native_ref, :non_json_value}} = HookContext.encode(issue)
  end

  test "rejects serialized context larger than the documented limit" do
    issue = %{
      id: "issue-1",
      identifier: "MT-1",
      native_ref: %{"repository" => %{"name" => String.duplicate("x", HookContext.max_bytes())}}
    }

    assert {:error, {:too_large, actual_bytes, max_bytes}} = HookContext.encode(issue)
    assert actual_bytes > max_bytes
    assert max_bytes == 16 * 1024
  end

  test "passes structured context to local hooks through the child environment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-hook-context-local-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      context_path = Path.join(test_root, "context.json")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"$SYMPHONY_ISSUE_CONTEXT\" > #{context_path}"
      )

      issue = %{
        id: "project-item-42",
        identifier: "owner/repository#42",
        title: "must not be exposed",
        description: "must not be exposed",
        native_ref: %{"repository" => %{"name" => "owner's/repository;safe"}}
      }

      assert {:ok, _workspace} = Workspace.create_for_issue(issue)
      context = Jason.decode!(File.read!(context_path))
      assert context["id"] == "project-item-42"
      assert context["identifier"] == "owner/repository#42"
      assert context["native_ref"]["repository"]["name"] == "owner's/repository;safe"
      refute Map.has_key?(context, "title")
      refute Map.has_key?(context, "description")
    after
      File.rm_rf(test_root)
    end
  end

  test "passes null context to before_remove without inventing an issue" do
    test_root = Path.join(System.tmp_dir!(), "symphony-hook-context-remove-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      context_path = Path.join(test_root, "remove-context.json")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "printf '%s' \"$SYMPHONY_ISSUE_CONTEXT\" > #{context_path}"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-REMOVE")
      assert :ok = Workspace.remove_issue_workspaces("MT-REMOVE")
      assert Jason.decode!(File.read!(context_path)) == %{"id" => nil, "identifier" => nil, "native_ref" => nil}
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rejecting oversized context preserves after_create failure and cleanup" do
    test_root = Path.join(System.tmp_dir!(), "symphony-hook-context-oversize-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "touch #{Path.join(test_root, "ran")}"
      )

      issue = %{
        id: "issue-1",
        identifier: "MT-1",
        native_ref: %{"ref" => String.duplicate("x", HookContext.max_bytes())}
      }

      assert {:error, {:workspace_hook_context_rejected, "after_create", {:too_large, _, _}}} =
               Workspace.create_for_issue(issue)

      refute File.exists?(Path.join(test_root, "ran"))
      refute File.exists?(Path.join(workspace_root, Workspace.workspace_key(issue)))
    after
      File.rm_rf(test_root)
    end
  end
end
