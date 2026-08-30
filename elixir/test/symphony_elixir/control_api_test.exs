defmodule SymphonyElixir.ControlApiTest do
  use ExUnit.Case

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    def control(command, params) do
      send(Process.get(:control_api_test_pid, self()), {:control, command, params})
      Process.get(:control_api_result, {:ok, %{control: %{state: :running}}})
    end
  end

  setup do
    previous_header_validation = Application.get_env(:plug, :validate_header_keys_during_test)
    previous_endpoint_config = Application.get_env(:symphony_elixir, @endpoint, [])
    SymphonyElixir.TestSupport.stop_default_http_server()

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(@endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:render_errors,
        formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON]
      )
      |> Keyword.put(:orchestrator, FakeOrchestrator)

    Application.put_env(:symphony_elixir, @endpoint, endpoint_config)
    Application.put_env(:plug, :validate_header_keys_during_test, false)
    start_supervised!({@endpoint, []})

    Process.put(:control_api_test_pid, self())
    Process.delete(:control_api_result)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, @endpoint, previous_endpoint_config)

      if is_nil(previous_header_validation) do
        Application.delete_env(:plug, :validate_header_keys_during_test)
      else
        Application.put_env(:plug, :validate_header_keys_during_test, previous_header_validation)
      end
    end)

    :ok
  end

  test "control routes dispatch commands to the configured orchestrator" do
    for {path, command} <- [
          {"/api/v1/control/pause", :pause},
          {"/api/v1/control/drain", :drain},
          {"/api/v1/control/resume", :resume},
          {"/api/v1/control/stop", :stop}
        ] do
      response = json_response(post(build_conn(), path, %{}), 200)

      assert response["ok"]
      assert response["command"] == Atom.to_string(command)
      assert %{"control" => %{"state" => "running"}} = response["payload"]
      assert_receive {:control, ^command, %{}}
    end
  end

  test "hard-stop requires explicit project and cgroup scope" do
    assert json_response(post(build_conn(), "/api/v1/control/hard-stop", %{}), 400) ==
             %{
               "error" => %{
                 "code" => "invalid_scope",
                 "message" => "Hard-stop requires an explicit project scope"
               }
             }

    refute_receive {:control, :hard_stop, _params}

    response =
      post(build_conn(), "/api/v1/control/hard-stop", %{
        "project" => "patches",
        "cgroup" => "user.slice/polyphony-patches"
      })

    assert json_response(response, 200)["ok"]

    assert_receive {:control, :hard_stop, %{scope: %{project: "patches", cgroup: "user.slice/polyphony-patches"}}}
  end

  test "unavailable and rejected controls return actionable errors" do
    Process.put(:control_api_result, :unavailable)

    assert json_response(post(build_conn(), "/api/v1/control/pause", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }

    Process.put(:control_api_result, {:error, :drain_in_progress})

    assert json_response(post(build_conn(), "/api/v1/control/drain", %{}), 409) ==
             %{
               "error" => %{
                 "code" => "control_rejected",
                 "message" => "Control command rejected: :drain_in_progress"
               }
             }
  end

  test "control routes reject non-POST requests" do
    assert json_response(get(build_conn(), "/api/v1/control/pause"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end
end
