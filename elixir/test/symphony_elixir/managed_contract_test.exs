defmodule SymphonyElixir.Managed.ContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Rules

  @fixture_path Path.expand("../fixtures/managed_control_fixture.json", __DIR__)

  test "shared bridge requests produce the documented control responses" do
    http = @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("http")
    bound = apply_example(Rules.new(), http["bind_project"])
    enrolled = apply_example(bound, http["enroll"])
    paused = apply_example(enrolled, http["pause"])
    apply_example(paused, http["resume"])
    apply_example(enrolled, http["revise"])
    apply_example(enrolled, http["cancel"])

    id = http["enroll"]["body"]["args"]["assignment_id"]
    active = put_in(enrolled, [:assignments, id, :phase], :active)
    apply_example(active, http["interrupt"])
    reviewable = put_in(enrolled, [:assignments, id, :phase], :review)

    apply_example(reviewable, http["review"], %{
      provider_state: :review,
      reconciled: true,
      external_effects: %{status: :ok, issue_close: :ok}
    })
  end

  test "shared route cases use the service escalation field" do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    bound = apply_example(Rules.new(), fixture["http"]["bind_project"])
    template = fixture["http"]["enroll"]["body"]

    for route_case <- fixture["route_cases"] do
      args = template["args"] |> Map.put("route", route_case["route"])
      args = Map.put(args, "escalation_reason", route_case["escalation_reason"])
      result = Rules.apply(bound, Map.put(template, "args", args))
      assert match?({:ok, _, _}, result) == route_case["accepted"]
    end
  end

  defp apply_example(state, example, context \\ %{}) do
    assert {:ok, next, response} = Rules.apply(state, example["body"], context)
    response = response |> Jason.encode!() |> Jason.decode!()
    assert Map.take(response, Map.keys(example["response"])) == example["response"]
    next
  end
end
