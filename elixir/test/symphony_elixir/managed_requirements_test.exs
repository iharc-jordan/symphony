defmodule SymphonyElixir.ManagedRequirementsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Managed.Requirements, PathSafety}

  test "reads and fingerprints only a canonical absolute REQUIREMENTS.md binding" do
    directory = Path.join(System.tmp_dir!(), "symphony-requirements-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "REQUIREMENTS.md")
    content = "- Preserve the current user decision.\n"

    File.mkdir_p!(directory)
    File.write!(path, content)

    on_exit(fn ->
      File.rm(path)
      File.rmdir(directory)
    end)

    assert {:ok, %{path: resolved_path, content: ^content, fingerprint: fingerprint}} =
             Requirements.read(%{requirements_path: path})

    assert PathSafety.same_path?(resolved_path, path)
    assert fingerprint == Requirements.fingerprint(content)
    assert {:error, :project_requirements_path_invalid} = Requirements.read(%{requirements_path: Path.join(directory, "notes.md")})
    assert {:ok, %{content: ^content}} = Requirements.read(%{"requirements_path" => path})
    assert {:error, :project_requirements_path_invalid} = Requirements.read(%{})
    assert {:error, :project_requirements_path_invalid} = Requirements.read(:invalid)
    assert {:error, :project_requirements_path_invalid} = Requirements.path(:invalid)
  end

  test "reports a missing bound requirements file" do
    path = Path.join(System.tmp_dir!(), "symphony-missing-#{System.unique_integer([:positive])}") |> Path.join("REQUIREMENTS.md")

    assert {:error, :project_requirements_missing} = Requirements.read(%{requirements_path: path})
  end

  test "rejects oversized and invalid requirement sources" do
    directory = Path.join(System.tmp_dir!(), "symphony-invalid-requirements-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "REQUIREMENTS.md")

    File.mkdir_p!(directory)

    on_exit(fn ->
      File.rm(path)
      File.rmdir(directory)
    end)

    File.write!(path, :binary.copy("x", 128 * 1024 + 1))
    assert {:error, :project_requirements_too_large} = Requirements.read(%{requirements_path: path})

    File.write!(path, <<255, 254>>)
    assert {:error, :project_requirements_invalid_encoding} = Requirements.read(%{requirements_path: path})
  end

  test "rejects a requirements path that is not a regular file" do
    directory = Path.join(System.tmp_dir!(), "symphony-requirements-directory-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "REQUIREMENTS.md")
    File.mkdir_p!(path)

    on_exit(fn -> File.rm_rf(directory) end)

    assert {:error, :project_requirements_not_regular_file} = Requirements.read(%{requirements_path: path})
  end
end
