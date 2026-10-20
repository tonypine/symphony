defmodule SymphonyElixir.QaDriver.Machine do
  @moduledoc """
  Tells whether the QA host (`auto_review.worker_host`) is the Symphony Mac itself, under any
  name: `localhost`, `127.0.0.1`, `::1`, its `.local` name or a LAN address. Names can't tell, so
  it compares the hardware: the `IOPlatformUUID` `ioreg -rd1 -c IOPlatformExpertDevice` prints on
  each machine. A VM has its own. A Symphony host that is not a Mac has none and is never the QA
  host.

  Every read goes through a command function shaped like `SymphonyElixir.QaDriver.Host.cmd/3`, so
  `SymphonyElixir.QaDriver` reads the QA host with its SSH `cmd` and tests fake both sides.
  """

  alias SymphonyElixir.QaDriver.Host

  @ioreg "/usr/sbin/ioreg"
  @ioreg_args ["-rd1", "-c", "IOPlatformExpertDevice"]
  @uuid ~r/"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]+)"/
  @timeout_ms 30_000
  @output_limit 64_000

  @type cmd :: (String.t(), [String.t()], keyword() -> {:ok, {String.t(), integer()}} | {:error, term()})

  @doc "The `IOPlatformUUID` of the machine `cmd` runs on, upper-cased."
  @spec platform_uuid(cmd()) :: {:ok, String.t()} | {:error, String.t()}
  def platform_uuid(cmd) do
    case cmd.(@ioreg, @ioreg_args, timeout_ms: @timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        case Regex.run(@uuid, output) do
          [_match, uuid] -> {:ok, String.upcase(uuid)}
          nil -> {:error, "ioreg printed no IOPlatformUUID"}
        end

      {:ok, {output, status}} ->
        {:error, "ioreg exited with status #{status}: #{String.slice(String.trim(output), -500, 500)}"}

      {:error, reason} ->
        {:error, "ioreg could not run: #{inspect(reason)}"}
    end
  end

  @doc """
  This host's `IOPlatformUUID`, or `nil` when it is not a Mac (`os_type` other than Darwin), which
  has no `ioreg`.
  """
  @spec local_uuid({atom(), atom()}, cmd()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def local_uuid(os_type \\ :os.type(), cmd \\ &Host.cmd/3) do
    if os_type == {:unix, :darwin}, do: platform_uuid(cmd), else: {:ok, nil}
  end

  @doc """
  Whether the QA host `qa_cmd` runs on is this host, as `local_uuid` (`local_uuid/0` in
  production) reads it. `{:error, reason}`
  when either side's UUID can't be read: a QA host Symphony can't tell apart from itself is not
  used.
  """
  @spec same_machine?(cmd(), (-> {:ok, String.t() | nil} | {:error, String.t()})) ::
          {:ok, boolean()} | {:error, String.t()}
  def same_machine?(qa_cmd, local_uuid) do
    with {:ok, local} <- side(local_uuid.(), "this host"),
         {:ok, qa} <- side(platform_uuid(qa_cmd), "the QA host") do
      {:ok, local == qa}
    end
  end

  defp side({:ok, uuid}, _where), do: {:ok, uuid}
  defp side({:error, reason}, where), do: {:error, "the hardware UUID of #{where} could not be read: #{reason}"}
end
