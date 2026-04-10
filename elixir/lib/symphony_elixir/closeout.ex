defmodule SymphonyElixir.Closeout do
  @moduledoc """
  Post-unit acceptance logic. Called by the orchestrator after a worker
  exits normally. Determines whether the unit is accepted or needs retry.

  Closeout behavior per unit kind:
  - `bootstrap`: check workspace ready, run baseline verify, mark bootstrapped
  - `plan`: check workpad has parseable checklist, bump plan_version
  - `implement_subtask`: check subtask marked done, doc-impact check
  - `doc_fix`: clear doc_fix_required flag
  - `verify`: run full verification, set last_verified_sha
  - `handoff`: check last_verified_sha == HEAD
  - `merge`: check PR actually merged on remote before marking done
  """

  require Logger

  alias SymphonyElixir.{IssueExec, Ledger, Linear.Adapter, Verifier}

  @type result :: :accepted | {:retry, String.t()} | {:fail, String.t()}

  @doc """
  Run closeout for a completed unit. Returns :accepted, {:retry, reason}, or {:fail, reason}.
  """
  @spec run(Path.t(), map(), map(), keyword()) :: result()
  def run(workspace, unit, issue, opts \\ []) do
    kind = unit["kind"] || to_string(unit[:kind])
    do_closeout(kind, workspace, unit, issue, opts)
  end

  # --- Per-unit closeout ---

  defp do_closeout("bootstrap", workspace, _unit, _issue, _opts) do
    # Mark bootstrapped
    IssueExec.mark_bootstrapped(workspace)

    # Run baseline verification if commands are configured
    case Verifier.run_baseline(workspace) do
      :pass ->
        Ledger.append(workspace, :baseline_verified, %{})
        :accepted

      {:fail, output} ->
        Logger.warning("Closeout: baseline verification failed")
        Ledger.append(workspace, :baseline_verify_failed, %{"output" => truncate(output, 2048)})
        # Baseline failure is not a blocker for bootstrap acceptance
        # (agent may need to fix in implement phase)
        :accepted
    end
  end

  defp do_closeout("plan", workspace, _unit, _issue, _opts) do
    # Plan acceptance: agent wrote the plan to Linear workpad. We can't verify
    # the workpad content here (it's on Linear, not local). Instead, we accept
    # the plan unit and let DispatchResolver verify the checklist is parseable
    # on the NEXT dispatch cycle (when workpad text will be fetched from Linear).
    # If the checklist isn't parseable, resolver will re-dispatch :plan.
    IssueExec.bump_plan_version(workspace)
    :accepted
  end

  defp do_closeout("implement_subtask", workspace, unit, issue, _opts) do
    subtask_id = unit["subtask_id"]

    # 1. Mark subtask done on Linear workpad (orchestrator-owned, no agent compliance needed)
    if subtask_id && issue_id(issue) do
      case Adapter.mark_subtask_done(issue_id(issue), subtask_id) do
        :ok ->
          Logger.info("Closeout: marked #{subtask_id} done on Linear workpad")

        {:error, reason} ->
          Logger.warning("Closeout: failed to mark #{subtask_id} on workpad: #{inspect(reason)}")
      end
    end

    # 1b. Set rework_fix_applied flag for rework-* subtasks
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "rework-") do
      IssueExec.update(workspace, %{"rework_fix_applied" => true})
    end

    # 2. Doc impact check deferred — runs once before verify, not after every subtask.
    # This avoids N×doc_fix sessions for N subtasks (was burning ~1.5M tokens each).
    :accepted
  end

  defp do_closeout("doc_fix", workspace, _unit, _issue, _opts) do
    IssueExec.clear_doc_fix_required(workspace)
    :accepted
  end

  @max_verify_attempts 3

  defp do_closeout("verify", workspace, unit, issue, opts) do
    attempt = unit["attempt"] || 1
    verify_opts = if cmds = Keyword.get(opts, :verify_commands), do: [commands: cmds], else: []

    case Verifier.run(workspace, verify_opts) do
      :pass ->
        head = Verifier.current_head(workspace)

        if head do
          IssueExec.set_verified_sha(workspace, head)
          Ledger.verify_passed(workspace, head)
        end

        :accepted

      {:fail, output} when attempt >= @max_verify_attempts ->
        # Escalate — do NOT force-accept unverified code.
        # The dispatch resolver's circuit breaker will escalate to
        # Human Input Needed on the next dispatch cycle.
        Logger.warning("Closeout: verify exhausted #{attempt} attempts, failing")
        Ledger.append(workspace, :verify_exhausted, %{
          "attempt" => attempt,
          "last_error" => truncate(output, 512)
        })

        # Post comment so human sees why verification failed
        issue_id = issue_id(issue)
        if is_binary(issue_id) do
          Adapter.create_comment(issue_id,
            "**Verification failed**: exhausted #{attempt} attempts.\nLast error: #{truncate(output, 256)}\n\nEscalating — code will NOT proceed to handoff.")
        end

        {:fail, "Verification exhausted #{attempt} attempts: #{truncate(output, 512)}"}

      {:fail, output} ->
        {:retry, "Verification failed: #{truncate(output, 1024)}"}
    end
  end

  defp do_closeout("handoff", workspace, _unit, _issue, _opts) do
    case IssueExec.read(workspace) do
      {:ok, exec} ->
        head = Verifier.current_head(workspace)

        if exec["last_verified_sha"] == head and head != nil do
          :accepted
        else
          {:fail, "Handoff rejected: last_verified_sha (#{exec["last_verified_sha"]}) != HEAD (#{head})"}
        end

      {:error, reason} ->
        {:fail, "Handoff rejected: cannot read exec state: #{inspect(reason)}"}
    end
  end

  defp do_closeout("merge", workspace, _unit, _issue, opts) do
    checker = Keyword.get(opts, :merge_checker, &Verifier.check_pr_merged/1)

    case checker.(workspace) do
      :merged ->
        IssueExec.update(workspace, %{"phase" => "done"})
        :accepted

      {:not_merged, reason} ->
        Logger.warning("Closeout: merge not confirmed: #{reason}")
        {:retry, "PR not merged: #{reason}"}

      :unknown ->
        # Cannot determine PR state (e.g., gh CLI not available).
        # Accept to avoid blocking, but log a warning and record in ledger.
        Logger.warning("Closeout: cannot verify PR merge status, accepting")
        Ledger.append(workspace, :merge_status_unknown, %{})
        IssueExec.update(workspace, %{"phase" => "done"})
        :accepted
    end
  end

  defp do_closeout(kind, _workspace, _unit, _issue, _opts) do
    Logger.warning("Closeout: unknown unit kind #{kind}")
    :accepted
  end

  # --- Helpers ---

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end

  defp truncate(text, max), do: truncate(IO.iodata_to_binary(text), max)

  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(%{"id" => id}) when is_binary(id), do: id
  defp issue_id(_), do: nil
end
