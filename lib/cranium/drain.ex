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
  @flush_delay_ms 2_000

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
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
    Cranium.Events.broadcast({:service_draining, %{reason: "sigterm"}})

    # Hold for @flush_delay_ms to ensure SSE clients receive the
    # service_draining event before we begin tearing down the
    # supervision tree.  Without this, System.stop/1 can shut down
    # Transport (Bandit) before the SSE handler processes flush the
    # event to the wire.
    Process.send_after(self(), :poll_drain, @flush_delay_ms)
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

  # An active inference is signaled by a {conversation_id, :agent} key
  # in ConversationRegistry — Harness registers this during inference
  # and unregisters after completion.
  defp active_round_count do
    Registry.select(Cranium.Inference.ConversationRegistry, [
      {{:"$1", :_, :_}, [{:is_tuple, :"$1"}, {:==, {:element, 2, :"$1"}, :agent}], [true]}
    ])
    |> length()
  end
end
