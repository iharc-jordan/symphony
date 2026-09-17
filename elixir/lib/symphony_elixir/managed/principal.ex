defmodule SymphonyElixir.Managed.Principal do
  @moduledoc """
  Authenticates the local operator or a Codex task credential minted by its
  trusted MCP bridge. Task credentials never grant operator authority.

  The bridge derives the task ID from Codex's per-call metadata, not tool
  arguments. This separates cooperating PMs on one host; it does not isolate
  mutually hostile processes that can read the operator's credential file.
  """

  @task_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @spec operator() :: map()
  def operator, do: %{principal_id: "operator", role: :operator, project_scope: :all}

  @spec authenticate(String.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, :unauthorized}
  def authenticate(token, secret) when is_binary(token) and is_binary(secret) and secret != "" do
    cond do
      equal?(token, secret) -> {:ok, operator()}
      String.starts_with?(token, "pm-v1.") -> authenticate_pm(token, secret)
      true -> {:error, :unauthorized}
    end
  end

  def authenticate(_token, _secret), do: {:error, :unauthorized}

  defp authenticate_pm(token, secret) do
    with ["pm-v1", task_id, signature] <- String.split(token, "."),
         true <- Regex.match?(@task_id, task_id),
         expected <- :crypto.mac(:hmac, :sha256, secret, "codex-orchestration-pm-v1:" <> task_id),
         true <- equal?(signature, Base.encode16(expected, case: :lower)) do
      {:ok, %{principal_id: task_id, role: :pm, project_scope: :all}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp equal?(left, right), do: byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
end
