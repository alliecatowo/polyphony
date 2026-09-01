defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_validation_marker "__SYMPHONY_WORKSPACE_VALIDATION__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, bootstrap_workspace, created?, workspace} <-
             ensure_workspace(workspace, safe_id, worker_host) do
        case maybe_run_after_create_hook(bootstrap_workspace, issue_context, created?, worker_host) do
          :ok ->
            with :ok <- validate_repository_workspace(bootstrap_workspace, issue_context, worker_host),
                 {:ok, workspace} <- finalize_workspace(bootstrap_workspace, workspace, created?, worker_host) do
              {:ok, workspace}
            else
              {:error, reason} = error ->
                rollback_bootstrap_workspace(bootstrap_workspace, workspace, created?, worker_host)

                error =
                  if not created? and bootstrap_workspace == workspace do
                    quarantine_invalid_workspace(error, workspace, worker_host)
                  else
                    error
                  end

                Logger.warning(
                  "Workspace validation/finalization rolled back #{issue_log_context(issue_context)} " <>
                    "worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}"
                )

                error
            end

          {:error, reason} = error ->
            # Never leave a newly-created directory behind after bootstrap
            # fails. Reusing it would skip after_create on the next retry and
            # strand the worker without its repository/branch.
            if created? do
              _ = remove_bootstrap_workspace(bootstrap_workspace, worker_host)
            end

            Logger.warning(
              "Workspace bootstrap rolled back #{issue_log_context(issue_context)} " <>
                "worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}"
            )

            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, safe_id, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false, workspace}

      File.exists?(workspace) ->
        with {:ok, _quarantine_path} <- quarantine_workspace(workspace),
             {:ok, bootstrap_workspace} <- create_workspace_stage(workspace, safe_id) do
          {:ok, bootstrap_workspace, true, workspace}
        end

      true ->
        with {:ok, bootstrap_workspace} <- create_workspace_stage(workspace, safe_id) do
          {:ok, bootstrap_workspace, true, workspace}
        end
    end
  end

  defp ensure_workspace(workspace, safe_id, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("safe_id", safe_id),
        "workspace_root=\"$(dirname \"$workspace\")\"",
        "bootstrap_root=\"$workspace_root/.symphony-bootstrap\"",
        "mkdir -p \"$bootstrap_root\"",
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "  bootstrap=\"$workspace\"",
        "elif [ -e \"$workspace\" ]; then",
        "  quarantine=\"$workspace_root/.\"$(basename \"$workspace\")\".quarantine-\"$(date +%s)-$$\"\"",
        "  mv \"$workspace\" \"$quarantine\"",
        "  bootstrap=\"$bootstrap_root/$safe_id\"",
        "  mkdir \"$bootstrap\"",
        "  created=1",
        "else",
        "  bootstrap=\"$bootstrap_root/$safe_id\"",
        "  if [ -e \"$bootstrap\" ]; then",
        "    quarantine=\"$bootstrap_root/.\"$safe_id\".quarantine-\"$(date +%s)-$$\"\"",
        "    mv \"$bootstrap\" \"$quarantine\"",
        "  fi",
        "  mkdir \"$bootstrap\"",
        "  created=1",
        "fi",
        "cd \"$bootstrap\"",
        "printf '%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$workspace\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace_stage(workspace, safe_id) do
    workspace_root = Path.dirname(workspace)
    bootstrap_root = Path.join(workspace_root, ".symphony-bootstrap")
    bootstrap_workspace = Path.join(bootstrap_root, safe_id)

    File.mkdir_p!(bootstrap_root)

    with :ok <- quarantine_existing_bootstrap(bootstrap_workspace),
         :ok <- File.mkdir(bootstrap_workspace) do
      {:ok, bootstrap_workspace}
    else
      {:error, :eexist} -> {:error, {:workspace_bootstrap_in_progress, bootstrap_workspace}}
      {:error, reason} -> {:error, {:workspace_bootstrap_failed, bootstrap_workspace, reason}}
    end
  end

  defp quarantine_existing_bootstrap(path) do
    if File.exists?(path) do
      case quarantine_workspace(path) do
        {:ok, _quarantine_path} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp quarantine_workspace(path) do
    quarantine_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.quarantine-#{System.unique_integer([:positive])}"
      )

    case File.rename(path, quarantine_path) do
      :ok -> {:ok, quarantine_path}
      {:error, reason} -> {:error, {:workspace_quarantine_failed, path, reason}}
    end
  end

  defp finalize_workspace(_bootstrap_workspace, workspace, false, _worker_host),
    do: {:ok, workspace}

  defp finalize_workspace(bootstrap_workspace, workspace, true, nil) do
    case File.rename(bootstrap_workspace, workspace) do
      :ok -> {:ok, workspace}
      {:error, reason} -> {:error, {:workspace_promote_failed, bootstrap_workspace, workspace, reason}}
    end
  end

  defp finalize_workspace(bootstrap_workspace, workspace, true, worker_host)
       when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("bootstrap", bootstrap_workspace),
        remote_shell_assign("workspace", workspace),
        "mv \"$bootstrap\" \"$workspace\"",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\n' '#{@remote_workspace_marker}' \"$(pwd -P)\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> {:ok, workspace}
      {:ok, {output, status}} -> {:error, {:workspace_promote_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_bootstrap_workspace(bootstrap_workspace, workspace, created?, worker_host) do
    if created? and bootstrap_workspace != workspace do
      _ = remove_bootstrap_workspace(bootstrap_workspace, worker_host)
    end

    :ok
  end

  defp quarantine_invalid_workspace({:error, reason}, workspace, nil) do
    case quarantine_workspace(workspace) do
      {:ok, quarantine_path} ->
        {:error, {:workspace_quarantined, reason, quarantine_path}}

      {:error, quarantine_reason} ->
        {:error, {:workspace_quarantine_failed, workspace, quarantine_reason}}
    end
  end

  defp quarantine_invalid_workspace(error, _workspace, _worker_host), do: error

  defp remove_bootstrap_workspace(path, nil), do: File.rm_rf(path)

  defp remove_bootstrap_workspace(path, worker_host) when is_binary(worker_host) do
    script = [remote_shell_assign("workspace", path), "rm -rf \"$workspace\""] |> Enum.join("\n")
    run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        bounded_command = bounded_hook_command(command, "before_remove", workspace)

        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{bounded_command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", bounded_hook_command(command, hook_name, workspace)], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    bounded_command = bounded_hook_command(command, hook_name, workspace)

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{bounded_command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded_hook_command(command, hook_name, workspace)
       when is_binary(command) and is_binary(hook_name) and is_binary(workspace) do
    # Hooks are intentionally short-lived. Disable Git's fsmonitor for them;
    # otherwise `git status`/`git switch` can leave a detached fsmonitor
    # daemon in the transient systemd scope after the hook exits.
    hook_command =
      "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false; " <>
        command

    Config.worker_resource_command("sh -lc #{shell_escape(hook_command)}", "hook-#{hook_name}-#{Path.basename(workspace)}")
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_repository_workspace(workspace, issue_context, nil) do
    strict_bootstrap? = repository_bootstrap_hook?()

    case git_top_level(workspace) do
      {:ok, top_level} ->
        with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
             {:ok, canonical_top_level} <- PathSafety.canonicalize(top_level),
             :ok <- ensure_workspace_top_level(canonical_top_level, canonical_workspace),
             :ok <- validate_workspace_remote(workspace),
             :ok <- validate_workspace_branch(workspace, issue_context) do
          :ok
        end

      {:error, _reason} when strict_bootstrap? ->
        {:error, {:workspace_missing_repository, workspace}}

      {:error, _reason} ->
        # Some callers intentionally use Workspace as a plain directory
        # lifecycle helper. Preserve that legacy behavior when no repository
        # bootstrap was requested, while never permitting Git to discover a
        # repository above the workspace.
        :ok
    end
  end

  defp validate_repository_workspace(workspace, issue_context, worker_host)
       when is_binary(worker_host) do
    if repository_bootstrap_hook?() do
      script =
        [
          "set +e",
          remote_shell_assign("workspace", workspace),
          "canonical=\"$(cd \"$workspace\" 2>/dev/null && pwd -P)\"",
          "top=\"$(git -C \"$workspace\" rev-parse --show-toplevel 2>/dev/null)\"",
          "remote=\"$(git -C \"$workspace\" remote get-url origin 2>/dev/null)\"",
          "branch=\"$(git -C \"$workspace\" branch --show-current 2>/dev/null)\"",
          "if [ -z \"$top\" ]; then status=missing; elif [ \"$top\" != \"$canonical\" ]; then status=parent; else status=ok; fi",
          "printf '%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@remote_validation_marker}' \"$status\" \"$canonical\" \"$top\" \"$remote|$branch\"",
          "exit 0"
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
        {:ok, {output, 0}} ->
          validate_remote_repository_output(output, workspace, issue_context)

        {:ok, {output, status}} ->
          {:error, {:workspace_validation_failed, worker_host, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp ensure_workspace_top_level(top_level, workspace) when top_level == workspace, do: :ok

  defp ensure_workspace_top_level(top_level, workspace),
    do: {:error, {:workspace_parent_repository, top_level, workspace}}

  defp git_top_level(workspace) do
    case run_git(workspace, ["rev-parse", "--show-toplevel"]) do
      {:ok, output} when byte_size(output) > 0 -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_workspace_remote(workspace) do
    case expected_repository() do
      nil ->
        :ok

      expected ->
        case run_git(workspace, ["remote", "get-url", "origin"]) do
          {:ok, remote} ->
            if remote_matches_repository?(String.trim(remote), expected) do
              :ok
            else
              {:error, {:workspace_wrong_remote, String.trim(remote), expected}}
            end

          {:error, _reason} ->
            {:error, {:workspace_missing_remote, expected}}
        end
    end
  end

  defp validate_workspace_branch(workspace, issue_context) do
    expected_branch = expected_issue_branch(issue_context)

    case run_git(workspace, ["branch", "--show-current"]) do
      {:ok, branch} ->
        validate_branch_name(branch, issue_context)

      {:error, _reason} ->
        {:error, {:workspace_detached_head, expected_branch}}
    end
  end

  defp validate_remote_repository_output(output, workspace, issue_context) do
    payload =
      output
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, "\t", parts: 5) do
          [@remote_validation_marker, status, canonical, top, remote_and_branch]
          when status in ["missing", "parent", "ok"] ->
            {status, canonical, top, remote_and_branch}

          _ ->
            nil
        end
      end)

    case payload do
      {"missing", _canonical, _top, _remote_and_branch} ->
        {:error, {:workspace_missing_repository, workspace}}

      {"parent", canonical, top, _remote_and_branch} ->
        {:error, {:workspace_parent_repository, top, canonical}}

      {"ok", canonical, canonical, remote_and_branch} ->
        case String.split(remote_and_branch, "|", parts: 2) do
          [remote, branch] ->
            with :ok <- validate_remote_identity(remote),
                 :ok <- validate_branch_name(branch, issue_context) do
              :ok
            end

          _ ->
            {:error, {:workspace_validation_failed, :remote, :invalid_output, output}}
        end

      _ ->
        {:error, {:workspace_validation_failed, :remote, :invalid_output, output}}
    end
  end

  defp validate_remote_identity(remote) do
    case expected_repository() do
      nil ->
        :ok

      expected ->
        if remote_matches_repository?(String.trim(remote), expected) do
          :ok
        else
          {:error, {:workspace_wrong_remote, String.trim(remote), expected}}
        end
    end
  end

  defp validate_branch_name(branch, issue_context) do
    expected_branch = expected_issue_branch(issue_context)

    case String.trim(branch) do
      ^expected_branch when expected_branch in ["main", "master", "trunk"] ->
        {:error, {:workspace_non_unique_branch, expected_branch}}

      ^expected_branch ->
        :ok

      actual ->
        {:error, {:workspace_wrong_branch, actual, expected_branch}}
    end
  end

  defp expected_issue_branch(%{issue_identifier: identifier, branch_name: branch_name}) do
    case branch_name do
      branch when is_binary(branch) ->
        case String.trim(branch) do
          "" -> "agent/polyphony-#{safe_identifier(identifier)}"
          normalized_branch -> normalized_branch
        end

      _ ->
        "agent/polyphony-#{safe_identifier(identifier)}"
    end
  end

  defp expected_repository do
    tracker = Config.settings!().tracker
    owner = tracker.repo_owner
    name = tracker.repo_name

    if is_binary(owner) and String.trim(owner) != "" and is_binary(name) and String.trim(name) != "" do
      "#{String.trim(owner)}/#{String.trim(name)}"
    else
      nil
    end
  end

  defp remote_matches_repository?(remote, expected) do
    normalized_remote = remote |> String.trim() |> String.trim_trailing(".git") |> String.downcase()
    normalized_expected = String.downcase(expected)

    String.ends_with?(normalized_remote, "/" <> normalized_expected) or
      String.ends_with?(normalized_remote, ":" <> normalized_expected) or
      normalized_remote == normalized_expected
  end

  defp repository_bootstrap_hook? do
    case Config.settings!().hooks.after_create do
      hook when is_binary(hook) ->
        String.match?(hook, ~r/(^|\s|[;&|])git\s+(clone|init|worktree|switch|checkout|remote)\b/)

      _ ->
        false
    end
  end

  defp run_git(workspace, arguments) when is_binary(workspace) and is_list(arguments) do
    case System.cmd("git", ["-C", workspace | arguments], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_command_failed, arguments, status, output}}
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      {:error, {:git_command_failed, arguments, error}}
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 4) do
          [@remote_workspace_marker, created, workspace, bootstrap]
          when created in ["0", "1"] and workspace != "" and bootstrap != "" ->
            {created == "1", bootstrap, workspace}

          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            # Compatibility with older remote workers and the fake SSH used
            # by the lifecycle tests.
            {created == "1", path, path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, bootstrap_workspace, workspace}
      when is_boolean(created?) and is_binary(bootstrap_workspace) and is_binary(workspace) ->
        {:ok, bootstrap_workspace, created?, workspace}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier, branch_name: branch_name}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      branch_name: branch_name
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      branch_name: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      branch_name: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      branch_name: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
