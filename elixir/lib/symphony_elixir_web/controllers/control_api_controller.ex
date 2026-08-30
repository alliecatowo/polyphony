defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc """
  JSON control API for the active Symphony runtime.

  Hard stops deliberately require an explicit project and cgroup scope.  The
  controller never turns a missing scope into a global process or host kill.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.Endpoint

  @type command :: :pause | :drain | :resume | :stop | :hard_stop

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params), do: dispatch(conn, :pause, params)

  @spec drain(Conn.t(), map()) :: Conn.t()
  def drain(conn, params), do: dispatch(conn, :drain, params)

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, params), do: dispatch(conn, :resume, params)

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, params), do: dispatch(conn, :stop, params)

  @spec hard_stop(Conn.t(), map()) :: Conn.t()
  def hard_stop(conn, params) do
    case normalize_scope(params) do
      {:ok, scope} -> dispatch(conn, :hard_stop, %{scope: scope})
      {:error, reason} -> error_response(conn, 400, "invalid_scope", scope_error_message(reason))
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp dispatch(conn, command, params) when command in [:pause, :drain, :resume, :stop] do
    control(conn, command, if(is_map(params), do: params, else: %{}))
  end

  defp dispatch(conn, :hard_stop, %{scope: scope}) do
    control(conn, :hard_stop, %{scope: scope})
  end

  defp control(conn, command, params) do
    case call_orchestrator(command, params) do
      {:ok, payload} ->
        json(conn, %{ok: true, command: command, payload: payload})

      {:error, reason} ->
        error_response(conn, 409, "control_rejected", control_error_message(reason))

      :unavailable ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  defp call_orchestrator(command, params) do
    orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator

    try do
      apply(orchestrator, :control, [command, params])
    rescue
      UndefinedFunctionError -> :unavailable
      _error -> :unavailable
    catch
      :exit, _reason -> :unavailable
    end
  end

  defp normalize_scope(params) when is_map(params) do
    scope = Map.get(params, "scope") || Map.get(params, :scope) || params
    project = value(scope, "project")
    cgroup = value(scope, "cgroup") || value(scope, "cgroup_scope")

    cond do
      not present_string?(project) -> {:error, :missing_project}
      not present_string?(cgroup) -> {:error, :missing_cgroup}
      true -> {:ok, %{project: project, cgroup: cgroup}}
    end
  end

  defp normalize_scope(_params), do: {:error, :invalid_scope}

  defp value(map, key) when is_map(map) do
    case key do
      "project" -> Map.get(map, key) || Map.get(map, :project)
      "cgroup" -> Map.get(map, key) || Map.get(map, :cgroup)
      "cgroup_scope" -> Map.get(map, key) || Map.get(map, :cgroup_scope)
    end
  end

  defp value(_map, _key), do: nil

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp scope_error_message(:missing_project), do: "Hard-stop requires an explicit project scope"
  defp scope_error_message(:missing_cgroup), do: "Hard-stop requires an explicit cgroup scope"
  defp scope_error_message(:invalid_scope), do: "Hard-stop scope must be an object"

  defp control_error_message(reason) when is_binary(reason), do: reason
  defp control_error_message(reason), do: "Control command rejected: #{inspect(reason)}"

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
