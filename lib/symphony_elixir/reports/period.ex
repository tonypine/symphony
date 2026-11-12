defmodule SymphonyElixir.Reports.Period do
  @moduledoc """
  The stretch of time a report covers: `from` and `to`, both UTC, `from` before `to`.

  `parse/2` reads a time as a person types it at `symphony report --from --to`: an ISO 8601
  timestamp (`2026-11-11T18:00:00Z`, or with an offset), `now`, `today` or `yesterday` (midnight),
  `today 09:30` or `yesterday 18:00`, a bare `18:00` (today), or `2 hours ago` (minutes, hours or
  days). A time without an offset is on this host's clock (`opts[:utc_offset]`, in seconds, default
  the host's offset now), as a person reading their own clock means it.
  """

  @type t :: %{from: DateTime.t(), to: DateTime.t()}

  @units %{"minute" => 60, "hour" => 3_600, "day" => 86_400}
  @clock ~r/\A(\d{1,2}):(\d{2})\z/
  @ago ~r/\A(\d+)\s*(minute|hour|day)s?\s+ago\z/

  @doc """
  The period from `from` to `to`, each a time `parse/2` reads, or `{:error, message}` saying what
  is wrong in plain words. `opts`: `now:` (a UTC `DateTime`, default now) and `utc_offset:`.
  """
  @spec new(String.t() | DateTime.t(), String.t() | DateTime.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(from, to, opts \\ []) do
    with {:ok, from} <- time(from, "--from", opts),
         {:ok, to} <- time(to, "--to", opts) do
      if DateTime.compare(from, to) == :lt,
        do: {:ok, %{from: from, to: to}},
        else: {:error, "The start of the period must come before its end."}
    end
  end

  defp time(%DateTime{} = at, _name, _opts), do: {:ok, at}

  defp time(text, name, opts) when is_binary(text) do
    case parse(text, opts) do
      {:ok, at} -> {:ok, at}
      :error -> {:error, "#{name} #{inspect(text)} is not a time: give an ISO 8601 time, now, today or yesterday with an hour such as 18:00, or 2 hours ago."}
    end
  end

  defp time(_value, name, _opts), do: {:error, "#{name} is required."}

  @doc "The UTC time `text` names (see the moduledoc), or `:error`."
  @spec parse(String.t(), keyword()) :: {:ok, DateTime.t()} | :error
  def parse(text, opts \\ []) when is_binary(text) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) |> DateTime.truncate(:second)
    offset = Keyword.get_lazy(opts, :utc_offset, &host_offset/0)
    text = text |> String.trim() |> String.downcase()

    case DateTime.from_iso8601(String.upcase(text)) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> words(text, now, offset)
    end
  end

  defp words("now", now, _offset), do: {:ok, now}

  defp words(text, now, offset) do
    cond do
      match = Regex.run(@ago, text) -> ago(match, now)
      Regex.match?(@clock, text) -> day_at(0, text, now, offset)
      true -> day(String.split(text, ~r/\s+/, parts: 2), now, offset)
    end
  end

  defp ago([_text, count, unit], now), do: {:ok, DateTime.add(now, -String.to_integer(count) * Map.fetch!(@units, unit), :second)}

  defp day(["today"], now, offset), do: day_at(0, "00:00", now, offset)
  defp day(["yesterday"], now, offset), do: day_at(-1, "00:00", now, offset)
  defp day(["today", clock], now, offset), do: day_at(0, clock, now, offset)
  defp day(["yesterday", clock], now, offset), do: day_at(-1, clock, now, offset)
  defp day(_words, _now, _offset), do: :error

  # The time `clock` of the local day `days` from today, back in UTC.
  defp day_at(days, clock, now, offset) do
    with [_clock, hour, minute] <- Regex.run(@clock, clock),
         {hour, minute} = {String.to_integer(hour), String.to_integer(minute)},
         true <- hour < 24 and minute < 60 do
      local = now |> DateTime.add(offset, :second) |> DateTime.to_date() |> Date.add(days)
      {:ok, naive} = NaiveDateTime.new(local, Time.new!(hour, minute, 0))
      {:ok, naive |> NaiveDateTime.add(-offset, :second) |> DateTime.from_naive!("Etc/UTC")}
    else
      _invalid -> :error
    end
  end

  defp host_offset do
    local = :calendar.local_time() |> NaiveDateTime.from_erl!()
    utc = :calendar.universal_time() |> NaiveDateTime.from_erl!()
    NaiveDateTime.diff(local, utc, :second)
  end
end
