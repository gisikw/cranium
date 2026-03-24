defmodule Cranium.Drain do
  @moduledoc """
  Graceful shutdown coordinator.

  Traps SIGTERM and transitions the application into drain mode:
  1. Reject new `/v1/submit` requests (HTTP returns 503)
  2. Wait for in-flight inference rounds to complete
  3. Stop the VM cleanly

  Uses `:persistent_term` for zero-cost drain state checks on the
  hot path (every HTTP request).
  """

  use GenServer

  require Logger

  @drain_key {__MODULE__, :draining}
  @poll_interval_ms 500

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true when the server is draining (rejecting new work)."
  @spec draining?() :: boolean()
  def draining? do
    :persistent_term.get(@drain_key, false)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :persistent_term.put(@drain_key, false)

    # Trap SIGTERM so the BEAM delivers it as a message instead of
    # immediately shutting down.
    :os.set_signal(:sigterm, :handle)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sigterm, state) do
    Logger.info("SIGTERM received — starting drain")
    :persistent_term.put(@drain_key, true)
    send(self(), :poll_drain)
    {:noreply, state}
  end

  def handle_info(:poll_drain, state) do
    active = active_round_count()

    if active == 0 do
      Logger.info("Drain complete — no active rounds, stopping")
      System.stop(0)
    else
      Logger.info("Draining — #{active} active round(s) remaining")
      Process.send_after(self(), :poll_drain, @poll_interval_ms)
    end

    {:noreply, state}
  end

  # --- Internals ---

  defp active_round_count do
    Cranium.Epoch.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.count(fn {_, pid, _, _} ->
      is_pid(pid) && epoch_busy?(pid)
    end)
  end

  defp epoch_busy?(pid) do
    try do
      case GenServer.call(pid, :get_status, 1_000) do
        %{status: status} when status in [:processing, :inferring] -> true
        _ -> false
      end
    catch
      :exit, _ -> false
    end
  end
end
