defmodule SymphonyElixir.ManagedConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  test "managed changeset requires nonblank journal and token file paths" do
    journal_changeset =
      Schema.Managed.changeset(%Schema.Managed{}, %{journal_path: "   "})

    refute journal_changeset.valid?
    assert journal_changeset.errors[:journal_path] == {"must not be blank", []}

    token_file_changeset =
      Schema.Managed.changeset(%Schema.Managed{}, %{control_token_file: " 	 "})

    refute token_file_changeset.valid?
    assert token_file_changeset.errors[:control_token_file] == {"must not be blank", []}

    valid_changeset =
      Schema.Managed.changeset(%Schema.Managed{}, %{
        journal_path: "/tmp/managed-journal.log",
        control_token_file: "/tmp/managed-token"
      })

    assert valid_changeset.valid?
  end

  test "managed config rejects missing and blank validation token files" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-config-token-#{System.unique_integer([:positive])}"
      )

    try do
      missing_token_file = Path.join(test_root, "missing-token")
      blank_token_file = Path.join(test_root, "blank-token")
      File.mkdir_p!(test_root)
      File.write!(blank_token_file, " 
")

      for token_file <- [missing_token_file, blank_token_file] do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{
                   managed: %{
                     enabled: true,
                     control_token_file: token_file
                   }
                 })

        assert message =~ "readable non-empty control_token_file or control_token"
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "managed config reports each required checkout path" do
    base = %{managed: %{enabled: true, control_token: "direct-token"}}

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(base)
    assert message == "managed.enabled=true requires managed.checkout_node"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               managed: Map.put(base.managed, :checkout_node, "/srv/managed/node")
             })

    assert message == "managed.enabled=true requires managed.checkout_helper_path"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               managed:
                 base.managed
                 |> Map.put(:checkout_node, "/srv/managed/node")
                 |> Map.put(:checkout_helper_path, "/srv/managed/helper")
             })

    assert message == "managed.enabled=true requires managed.checkout_policy_file"
  end

  test "managed config loads the token file and normalizes managed settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-config-success-#{System.unique_integer([:positive])}"
      )

    try do
      token_file = Path.join(test_root, "token")
      journal_path = Path.join(test_root, "journal.log")
      File.mkdir_p!(test_root)
      File.write!(token_file, " file-token 
")

      assert {:ok, settings} =
               Schema.parse(%{
                 managed: %{
                   enabled: true,
                   journal_path: journal_path,
                   control_token: "fallback-token",
                   control_token_file: token_file,
                   control_token_env: "CUSTOM_MANAGED_TOKEN",
                   event_limit: 25,
                   event_wait_ms: 0,
                   checkout_node: "/srv/managed/node",
                   checkout_helper_path: "/srv/managed/helper",
                   checkout_policy_file: "/srv/managed/policy",
                   token_limit: 17
                 }
               })

      assert settings.managed.enabled
      assert settings.managed.journal_path == journal_path
      assert settings.managed.control_token == "file-token"
      assert settings.managed.control_token_file == token_file
      assert settings.managed.event_limit == 25
      assert settings.managed.event_wait_ms == 0
      assert settings.managed.checkout_node == "/srv/managed/node"
      assert settings.managed.checkout_helper_path == "/srv/managed/helper"
      assert settings.managed.checkout_policy_file == "/srv/managed/policy"
      assert settings.managed.usage_limit_tokens == 17
      assert settings.managed.token_limit == 17
    after
      File.rm_rf(test_root)
    end
  end
end
