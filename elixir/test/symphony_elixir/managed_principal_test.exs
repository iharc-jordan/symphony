defmodule SymphonyElixir.Managed.PrincipalTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Managed.Principal

  test "task capabilities authenticate independently and never become operators" do
    secret = "operator-fixture-secret"
    first = "00000000-0000-4000-8000-000000000001"
    second = "00000000-0000-4000-8000-000000000002"

    assert {:ok, %{role: :pm, principal_id: ^first}} = Principal.authenticate(credential(first, secret), secret)
    assert {:ok, %{role: :pm, principal_id: ^second}} = Principal.authenticate(credential(second, secret), secret)
    assert {:ok, %{role: :operator}} = Principal.authenticate(secret, secret)

    assert {:error, :unauthorized} =
             Principal.authenticate(String.replace(credential(first, secret), first, second), secret)

    assert {:error, :unauthorized} = Principal.authenticate(credential(first, "wrong-secret"), secret)
    assert {:error, :unauthorized} = Principal.authenticate(credential("operator", secret), secret)
    assert {:error, :unauthorized} = Principal.authenticate("pm-v1.#{first}.invalid", secret)
    assert {:error, :unauthorized} = Principal.authenticate("pm-v1.too.many.parts", secret)
    assert {:error, :unauthorized} = Principal.authenticate(nil, secret)
    assert {:error, :unauthorized} = Principal.authenticate(secret, "")
    assert {:error, :unauthorized} = Principal.authenticate("unrecognized", secret)
  end

  defp credential(id, secret) do
    signature = :crypto.mac(:hmac, :sha256, secret, "codex-orchestration-pm-v1:" <> id)
    "pm-v1.#{id}.#{Base.encode16(signature, case: :lower)}"
  end
end
