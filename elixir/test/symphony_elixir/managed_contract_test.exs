defmodule SymphonyElixir.Managed.ContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.{Ownership, Rules}

  @fixture_path Path.expand("../fixtures/managed_control_fixture.json", __DIR__)
  @operator %{principal_id: "operator", role: :operator, project_scope: :all}
  @pm_a %{principal_id: "00000000-0000-4000-8000-000000000001", role: :pm, project_scope: :all}
  @pm_b %{principal_id: "00000000-0000-4000-8000-000000000002", role: :pm, project_scope: :all}

  test "shared bridge requests cover the v2 managed control surface" do
    fixture = load_fixture()
    operations = fixture["http"] |> Map.keys() |> Enum.filter(&(&1 not in ["state", "events", "errors"])) |> Enum.sort()
    expected = ~w(bind_project register_pm claim enroll revise pause resume interrupt cancel review handoff) |> Enum.sort()

    assert operations == expected
    assert Enum.sort(Enum.map(Rules.allowed_operations(), &Atom.to_string/1)) == Enum.sort(expected ++ ["operator_takeover"])

    for operation <- expected do
      example = fixture["http"][operation]
      assert example["method"] == "POST"
      assert example["path"] == "/api/v1/managed/control"
      assert example["body"]["operation"] == operation
      assert is_binary(example["body"]["request_id"])
      assert example["response"]["operation"] == operation
    end
  end

  test "shared bridge requests produce the documented control responses" do
    http = load_fixture()["http"]
    bound = apply_example(Rules.new(), http["bind_project"], @operator)
    enrolled = apply_example(bound, http["enroll"], @pm_a)

    # Claim is exercised against the same wire shape after ownership is reset.
    unowned = put_in(enrolled, [:assignments, "item-one", :ownership], Ownership.unassigned())
    apply_example(unowned, http["claim"], @pm_a)

    apply_example(enrolled, http["revise"], @pm_a)
    paused = apply_example(enrolled, http["pause"], @pm_a)
    apply_example(paused, http["resume"], @pm_a)

    active = put_in(enrolled, [:assignments, "item-one", :phase], :active)
    active = put_in(active, [:assignments, "item-one", :board_state], :active)
    apply_example(active, http["interrupt"], @pm_a)
    apply_example(active, http["cancel"], @pm_a)

    reviewable = put_in(enrolled, [:assignments, "item-one", :phase], :review)
    reviewable = put_in(reviewable, [:assignments, "item-one", :board_state], :review)

    apply_example(reviewable, http["review"], @pm_a, %{
      provider_state: :review,
      reconciled: true,
      external_effects: %{status: :ok, issue_close: :ok}
    })

    # Registration is authenticated by the HTTP boundary. Seed the target
    # metadata here so the pure rules test can exercise the handoff envelope.
    handoff_state = put_in(enrolled, [:principals, @pm_b.principal_id], %{principal_id: @pm_b.principal_id, role: :pm})
    apply_example(handoff_state, http["handoff"], @pm_a, %{target_principal_id: @pm_b.principal_id})

    # register_pm is covered by the operation and response shape assertion above;
    # its principal is supplied by trusted request metadata rather than args.
    assert http["register_pm"]["body"]["args"] == %{"display_name" => "PM B"}
  end

  test "shared route cases use the service escalation field" do
    fixture = load_fixture()
    bound = apply_example(Rules.new(), fixture["http"]["bind_project"], @operator)
    template = fixture["http"]["enroll"]["body"]

    for {route_case, index} <- Enum.with_index(fixture["route_cases"]) do
      args =
        template["args"]
        |> Map.put("assignment_id", "route-item-#{index}")
        |> Map.put("route", route_case["route"])
        |> Map.put("escalation_reason", route_case["escalation_reason"])

      result = Rules.apply(bound, Map.put(template, "args", args), %{principal: @pm_a})
      assert match?({:ok, _, _}, result) == route_case["accepted"]
    end
  end

  defp load_fixture do
    @fixture_path |> File.read!() |> Jason.decode!()
  end

  defp apply_example(state, example, principal, context \\ %{}) do
    request = example["body"]
    context = Map.merge(%{principal: principal}, context)
    assert {:ok, next, response} = Rules.apply(state, request, context)
    response = response |> Jason.encode!() |> Jason.decode!()
    assert_json_subset(example["response"], response)
    next
  end

  defp assert_json_subset(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.each(expected, fn {key, value} ->
      assert Map.has_key?(actual, key), "expected response key #{inspect(key)}"
      assert_json_subset(value, Map.fetch!(actual, key))
    end)
  end

  defp assert_json_subset(expected, actual) when is_list(expected) and is_list(actual) do
    assert length(expected) == length(actual)
    Enum.zip(expected, actual) |> Enum.each(fn {left, right} -> assert_json_subset(left, right) end)
  end

  defp assert_json_subset(expected, actual), do: assert(expected == actual)
end
