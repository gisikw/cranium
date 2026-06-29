defmodule Cranium.RoomSync.EventCleanup do
  @moduledoc """
  Periodic cleanup of aged-out room events.

  Room events exist to power the sync protocol — clients catch up via
  `list_room_events(since_seq)` and then switch to live SSE. Events older
  than the retention window are unlikely to be requested and can be purged.

  Runs every hour, deletes events older than the configured retention period
  (default 24 hours).
  """

  use GenServer
  require Logger

  @default_retention_hours 24
  @sweep_interval_ms :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    retention_hours =
      Application.get_env(:cranium, :room_event_retention_hours, @default_retention_hours)

    cutoff = DateTime.add(DateTime.utc_now(), -retention_hours, :hour)

    case Cranium.Store.purge_room_events_before(cutoff) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Room event cleanup: purged #{count} events older than #{retention_hours}h")

      {:error, reason} ->
        Logger.error("Room event cleanup failed: #{inspect(reason)}")
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
