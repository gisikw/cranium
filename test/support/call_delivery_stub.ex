defmodule Cranium.Test.CallDeliveryStub do
  @moduledoc """
  Test stand-in for `Cranium.Calls.Delivery`.

  Instead of submitting a real pass (which would spawn a live
  conversation and run inference), forwards the delivery request to the
  pid registered under `:call_delivery_test_pid` and returns a fresh
  stream id, so tests can observe exactly what would have landed in the
  target room and drive the receiver side by hand.
  """

  @behaviour Cranium.Calls.Delivery

  @impl true
  def deliver(request) do
    stream_id = "stub-stream-" <> Integer.to_string(System.unique_integer([:positive]))

    case Application.get_env(:cranium, :call_delivery_test_pid) do
      pid when is_pid(pid) -> send(pid, {:call_delivered, request, stream_id})
      _ -> :ok
    end

    {:ok, stream_id}
  end
end
