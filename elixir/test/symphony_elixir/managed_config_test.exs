defmodule SymphonyElixir.ManagedConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  test "managed changeset requires nonblank SQLite store and token file paths" do
    store_changeset =
      Schema.Managed.changeset(%Schema.Managed{}, %{store_path: "   "})

    refute store_changeset.valid?
    assert store_changeset.errors[:store_path] == {"must not be blank", []}

    token_file_changeset =
      Schema.Managed.changeset(%Schema.Managed{}, %{control_token_file: " 	 "})

    refute token_file_changeset.valid?
    assert token_file_changeset.errors[:control_token_file] == {"must not be blank", []}

    valid_changeset =
      Schema.Managed.changeset(%Schema.Managed{}, %{
        store_path: "C:/fixture/managed.sqlite3",
        control_token_file: "C:/fixture/managed-token"
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

  test "managed config loads the token file and normalizes managed settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-config-success-#{System.unique_integer([:positive])}"
      )

    try do
      token_file = Path.join(test_root, "token")
      store_path = Path.join(test_root, "managed.sqlite3")
      File.mkdir_p!(test_root)
      File.write!(token_file, " file-token 
")

      assert {:ok, settings} =
               Schema.parse(%{
                 managed: %{
                   enabled: true,
                   store_path: store_path,
                   control_token: "fallback-token",
                   control_token_file: token_file,
                   control_token_env: "CUSTOM_MANAGED_TOKEN",
                   event_limit: 25,
                   event_wait_ms: 0,
                   usage_limit_tokens: 17
                 }
               })

      assert settings.managed.enabled
      assert settings.managed.store_path == store_path
      assert settings.managed.control_token == "file-token"
      assert settings.managed.control_token_file == token_file
      assert settings.managed.event_limit == 25
      assert settings.managed.event_wait_ms == 0
      assert settings.managed.usage_limit_tokens == 17
    after
      File.rm_rf(test_root)
    end
  end

  test "config rejects a missing launcher when APPDATA cannot supply the default" do
    previous_app_data = System.get_env("APPDATA")
    System.delete_env("APPDATA")
    on_exit(fn -> restore_env("APPDATA", previous_app_data) end)

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{})
    assert message =~ "codex.launcher is required"
  end
end
