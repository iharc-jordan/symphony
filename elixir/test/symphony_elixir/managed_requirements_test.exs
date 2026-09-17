defmodule SymphonyElixir.ManagedRequirementsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Requirements

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

    assert {:ok, %{path: ^path, content: ^content, fingerprint: fingerprint}} =
             Requirements.read(%{requirements_path: path})

    assert fingerprint == Requirements.fingerprint(content)
    assert {:error, :project_requirements_path_invalid} = Requirements.read(%{requirements_path: Path.join(directory, "notes.md")})
  end

  test "reports a missing bound requirements file" do
    path = Path.join(System.tmp_dir!(), "symphony-missing-#{System.unique_integer([:positive])}") |> Path.join("REQUIREMENTS.md")

    assert {:error, :project_requirements_missing} = Requirements.read(%{requirements_path: path})
  end
end
