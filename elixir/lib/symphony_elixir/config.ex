defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.Auth
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a tracker issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @doc "Returns the maximum counted repair turns for one persisted delivery."
  @spec max_delivery_retry_attempts() :: pos_integer()
  def max_delivery_retry_attempts, do: settings!().agent.max_delivery_retry_attempts

  @doc "Selects a Codex model profile for an issue."
  @spec codex_model_for_issue(map(), keyword()) :: String.t() | nil
  def codex_model_for_issue(issue, opts \\ []) do
    models = settings!().codex.models || %{}
    labels = issue |> Map.get(:labels, Map.get(issue, "labels", [])) |> normalize_worker_labels()
    metadata = Map.get(issue, :tracker_metadata, Map.get(issue, "tracker_metadata", %{}))
    failure_attempt = Keyword.get(opts, :failure_attempt) || Map.get(metadata, "failure_attempt", 0)
    failure_class = Keyword.get(opts, :failure_class) || Map.get(metadata, "failure_class")
    escalatable_failure? = failure_class in [:code, :ci, :merge_conflict, "code", "ci", "merge_conflict"]
    explicit_sol? = explicit_sol_escalation?(labels, metadata, opts)

    profile =
      cond do
        explicit_sol? -> "escalation"
        escalatable_failure? and is_integer(failure_attempt) and failure_attempt >= 3 -> "escalation"
        escalatable_failure? and is_integer(failure_attempt) and failure_attempt >= 2 -> "review"
        Enum.any?(labels, &(&1 in ["audit", "escalate", "escalation", "sol"])) -> "review"
        Enum.any?(labels, &(&1 in ["review", "stack", "stacked-pr", "stack-reconcile", "stack/reconcile"])) -> "review"
        true -> "default"
      end

    case Map.get(models, profile) || Map.get(models, "default") do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @doc "Returns the configured worker pool for an issue and retry attempt."
  @spec worker_hosts_for_issue(map(), integer() | nil) :: [String.t()]
  def worker_hosts_for_issue(issue, attempt \\ nil) do
    issue = if is_map(issue), do: issue, else: %{}
    worker = settings!().worker
    configured_hosts = normalize_worker_hosts(worker.ssh_hosts)
    routing = if is_map(worker.routing), do: worker.routing, else: %{}
    labels = issue |> Map.get(:labels, Map.get(issue, "labels", [])) |> normalize_worker_labels()
    state = issue |> Map.get(:state, Map.get(issue, "state", "")) |> normalize_worker_label()

    pr_lifecycle =
      issue
      |> Map.get(:tracker_metadata, %{})
      |> Map.get("pull_request_lifecycle", %{})

    stack_ready? = Map.get(pr_lifecycle, "ready_for_review", false) == true
    retry_attempt = if is_integer(attempt) and attempt > 0, do: attempt, else: 0
    explicit_sol? = explicit_sol_escalation?(labels, Map.get(issue, :tracker_metadata, %{}), [])

    pool_name =
      cond do
        explicit_sol? -> "escalation"
        stack_ready? -> "review"
        Enum.any?(labels, &(&1 in ["review", "stack", "stacked-pr", "stack-reconcile", "stack/reconcile"])) -> "review"
        String.contains?(state, "review") -> "review"
        true -> routing_string(routing, "default_pool", "default")
      end

    pool_hosts = Map.get(routing, pool_name)

    case normalize_worker_hosts(pool_hosts) |> Enum.filter(&(&1 in configured_hosts)) do
      [] -> configured_hosts
      hosts -> hosts
    end
  end

  @doc "Returns a bounded systemd-run prefix for a worker process tree."
  @spec worker_resource_command(String.t(), String.t()) :: String.t()
  def worker_resource_command(command, unit_suffix) when is_binary(command) and is_binary(unit_suffix) do
    worker = settings!().worker
    unit = "polyphony-agent-" <> sanitize_unit_suffix(unit_suffix)

    prefix =
      [
        "systemd-run --user --scope --quiet --collect --expand-environment=no",
        "--unit=#{unit}",
        "--property=CPUQuota=#{worker.cpu_quota_percent}%",
        "--property=MemoryMax=#{worker.memory_max_mb}M",
        "--property=TasksMax=#{worker.tasks_max}",
        "--property=OOMPolicy=kill",
        "--property=KillMode=control-group"
      ]
      |> Enum.join(" ")

    if worker.cgroup_required and not test_environment?() do
      prefix <> " -- " <> command
    else
      if test_environment?() do
        command
      else
        "if command -v systemd-run >/dev/null 2>&1; then exec #{prefix} -- #{command}; else exec #{command}; fi"
      end
    end
  end

  defp test_environment? do
    System.get_env("MIX_ENV") == "test" or
      (Code.ensure_loaded?(Mix) and Mix.env() == :test)
  end

  defp sanitize_unit_suffix(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")
    |> String.slice(0, 50)
    |> case do
      "" -> "worker"
      sanitized -> sanitized
    end
  end

  defp normalize_worker_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_worker_hosts(host) when is_binary(host), do: [String.downcase(String.trim(host))]
  defp normalize_worker_hosts(_hosts), do: []

  defp normalize_worker_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_worker_labels(label) when is_binary(label), do: [String.downcase(String.trim(label))]
  defp normalize_worker_labels(_labels), do: []

  # Sol is intentionally premium and must not be selected merely because an
  # issue has failed repeatedly or has a broad audit/escalation label. The
  # explicit marker can be set either on the issue metadata or by the caller.
  defp explicit_sol_escalation?(labels, metadata, opts) when is_list(labels) and is_map(metadata) do
    explicit_marker?(Keyword.get(opts, :escalate)) or
      explicit_marker?(Map.get(metadata, "escalate") || Map.get(metadata, :escalate)) or
      Enum.any?(labels, &(&1 in ["escalate: sol", "escalate:sol"]))
  end

  defp explicit_sol_escalation?(_labels, _metadata, _opts), do: false

  defp explicit_marker?(value) when value in [:sol, "sol"], do: true
  defp explicit_marker?(value) when is_binary(value), do: String.downcase(String.trim(value)) == "sol"
  defp explicit_marker?(_value), do: false

  defp normalize_worker_label(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_worker_label(value), do: value |> to_string() |> normalize_worker_label()

  defp routing_string(routing, key, default) do
    case Map.get(routing, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp routing_integer(routing, key, default) do
    case Map.get(routing, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} -> number
          _ -> default
        end

      _ ->
        default
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    Application.get_env(:symphony_elixir, :server_host_override, settings!().server.host)
  end

  @spec server_public_host() :: String.t() | nil
  def server_public_host do
    Application.get_env(:symphony_elixir, :server_public_host_override)
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["github", "linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "github" and not Auth.github_auth_available?(settings.tracker) ->
        {:error, :missing_github_api_token}

      settings.tracker.kind == "github" and not present_string?(settings.tracker.repo_owner) ->
        {:error, :missing_github_repo_owner}

      settings.tracker.kind == "github" and not present_string?(settings.tracker.repo_name) ->
        {:error, :missing_github_repo_name}

      settings.tracker.kind == "github" and not valid_status_map?(settings.tracker.status_map) ->
        {:error, :invalid_github_status_map}

      settings.tracker.kind == "linear" and not present_string?(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not present_string?(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp valid_status_map?(status_map) when is_map(status_map) do
    Enum.all?(status_map, fn {status_name, mapping} ->
      present_string?(to_string(status_name)) and valid_status_mapping?(mapping)
    end)
  end

  defp valid_status_map?(_), do: false

  defp valid_status_mapping?(%{"state" => state} = mapping) when state in ["open", "closed"] do
    case Map.get(mapping, "state_reason") do
      nil -> true
      reason when state == "closed" and reason in ["completed", "not_planned"] -> true
      _ -> false
    end
  end

  defp valid_status_mapping?(_), do: false
end
