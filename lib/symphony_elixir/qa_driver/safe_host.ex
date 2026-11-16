defmodule SymphonyElixir.QaDriver.SafeHost do
  @moduledoc """
  The checks every use of the QA host (`auto_review.worker_host`) passes before it runs anything
  there, shared by a QA pass (`SymphonyElixir.QaDriver`) and the QA pre-build
  (`SymphonyElixir.QaBuild`).

  `open/3` refuses no host at all (PR code never builds or runs on the Symphony host), a host that
  is the Symphony Mac under another name (`SymphonyElixir.QaDriver.Machine`), and one that could
  reach the operator's credentials (the host's `prepare`, `SymphonyElixir.QaDriver.Remote.prepare/3`,
  which reads a canary file only the operator can read). A host that passes gets a run directory
  of its own, which the caller removes with the host's `cleanup` when it is done.

  A refusal is `{:error, {code, message}}`: the `qa_worker_*` code and the message the QA agent
  reads. Each is logged here, named after `:user` (the QA driver, the QA build).
  """

  require Logger

  alias SymphonyElixir.QaDriver.{Checks, Machine}

  @qa_vm_docs "docs/configuration.md#running-qa-in-a-qa-vm"

  @type refusal :: {String.t(), String.t()}

  @doc """
  Checks `worker_host` and creates a run directory on it. `host` is its OS boundary (`cmd` and
  `prepare` of `t:SymphonyElixir.QaDriver.host/0`). Options: `:scratch_dir` (required, a private
  local directory the canary file is written to), `:local_uuid` (reads this host's
  `IOPlatformUUID`, default `SymphonyElixir.QaDriver.Machine.local_uuid/0`) and `:user` (who asks,
  for the logs, default `"QA driver"`).
  """
  @spec open(map(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, refusal()}
  def open(_host, nil, opts) do
    Logger.warning("#{user(opts)} has no worker_host: macos_app QA runs only in a QA VM")

    {:error,
     {"qa_worker_missing",
      "No QA VM is set up: `auto_review.worker_host` is unset, and Symphony never builds or runs a PR's macOS app on its own host. " <>
        "#{Checks.blocked_hint()} An operator sets up a QA VM and names it in `auto_review.worker_host` (see #{@qa_vm_docs})."}}
  end

  # The same hardware is the Symphony Mac under another name (`localhost`, its
  # `.local` name, a LAN address), whichever user it logs in as.
  def open(host, worker_host, opts) do
    case Machine.same_machine?(host.cmd, Keyword.get(opts, :local_uuid, &Machine.local_uuid/0)) do
      {:ok, false} ->
        prepare(host, worker_host, opts)

      {:ok, true} ->
        Logger.warning("#{user(opts)} refused worker_host=#{worker_host}: it is the Symphony host")

        {:error,
         {"qa_worker_same_machine",
          "The QA host #{worker_host} is this Mac (the same IOPlatformUUID): QA must run in a VM, never on the Symphony host, " <>
            "where PR code would run beside the operator's credentials. #{Checks.blocked_hint()} " <>
            "An operator points `auto_review.worker_host` at a QA VM (see #{@qa_vm_docs})."}}

      {:error, reason} ->
        Logger.warning("#{user(opts)} could not tell worker_host=#{worker_host} from the Symphony host: #{reason}")
        {:error, {"qa_worker_unreachable", "The QA host #{worker_host} could not be checked: #{reason}. #{Checks.blocked_hint()}"}}
    end
  end

  # Only the operator can read the canary, so a QA host that reads it runs as the operator.
  defp prepare(host, worker_host, opts) do
    canary = Path.join(Keyword.fetch!(opts, :scratch_dir), "canary")
    File.write!(canary, "")
    File.chmod!(canary, 0o600)

    case host.prepare.(System.user_home!(), canary) do
      {:ok, dir} ->
        Logger.info("#{user(opts)} runs on worker_host=#{worker_host} dir=#{dir}")
        {:ok, dir}

      {:error, {:unsafe, problems}} ->
        Logger.warning("#{user(opts)} refused worker_host=#{worker_host}: #{problems}")

        {:error,
         {"qa_worker_unsafe",
          "The QA host #{worker_host} #{problems}. QA must not run where PR code can reach push credentials. " <>
            "#{Checks.blocked_hint()} An operator fixes the QA host (see docs/configuration.md, macOS app QA)."}}

      {:error, {:unreachable, reason}} ->
        Logger.warning("#{user(opts)} could not reach worker_host=#{worker_host}: #{reason}")
        {:error, {"qa_worker_unreachable", "The QA host #{worker_host} could not be prepared: #{reason}. #{Checks.blocked_hint()}"}}
    end
  end

  defp user(opts), do: Keyword.get(opts, :user, "QA driver")
end
