defmodule Cranium.RoomSync.EventStreamTest do
  @moduledoc """
  Tests for the room event stream, including ephemeral turn events.

  Verifies that the EventStream correctly forwards both durable
  RoomEvents and ephemeral mid-turn events (text deltas, tool_use,
  tool_result) to SSE clients.
  """

  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.RoomSync.EventStream

  setup do
    room_id = "evstream-test-#{Ecto.UUID.generate()}"
    {:ok, _} = Cranium.Store.get_or_create_epoch(room_id)

    # Store room_id in persistent_term so the plug can read it
    key = {__MODULE__, :room_id}
    :persistent_term.put(key, room_id)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.StreamPlug, room_id_key: key},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      :persistent_term.erase(key)
      # Bandit holds SSE connections open; brutal kill avoids timeout
      Process.exit(server, :kill)
    end)

    {:ok, room_id: room_id, port: port}
  end

  describe "ephemeral event formatting" do
    test "text delta chunks are forwarded as turn.delta events", %{room_id: room_id, port: port} do
      events = with_sse_client(port, fn ->
        Cranium.Events.broadcast(room_id, {:chunk, "stream-1", "Hello "})
        Cranium.Events.broadcast(room_id, {:chunk, "stream-1", "world!"})
        Process.sleep(100)
      end)

      deltas = filter_events(events, "turn.delta")
      assert length(deltas) >= 2

      [first, second | _] = deltas
      assert first["type"] == "turn.delta"
      assert first["payload"]["content"] == "Hello "
      assert first["seq"] == nil
      assert first["room_id"] == room_id

      assert second["payload"]["content"] == "world!"
    end

    test "tool_use events are forwarded as turn.tool_use", %{room_id: room_id, port: port} do
      tool_data = %{
        id: "tool_abc",
        name: "mcp__tiamat__bash",
        input: %{"command" => "echo hi"}
      }

      events = with_sse_client(port, fn ->
        Cranium.Events.broadcast(room_id, {:chunk, "stream-1", {:tool_use, tool_data}})
        Process.sleep(100)
      end)

      tool_events = filter_events(events, "turn.tool_use")
      assert length(tool_events) >= 1

      [event | _] = tool_events
      assert event["type"] == "turn.tool_use"
      assert event["payload"]["id"] == "tool_abc"
      assert event["payload"]["name"] == "mcp__tiamat__bash"
      assert event["payload"]["input"] == %{"command" => "echo hi"}
      assert event["seq"] == nil
    end

    test "tool_result events are forwarded as turn.tool_result", %{room_id: room_id, port: port} do
      result_data = %{
        tool_use_id: "tool_abc",
        content: "hi\n",
        is_error: false
      }

      events = with_sse_client(port, fn ->
        Cranium.Events.broadcast(room_id, {:chunk, "stream-1", {:tool_result, result_data}})
        Process.sleep(100)
      end)

      result_events = filter_events(events, "turn.tool_result")
      assert length(result_events) >= 1

      [event | _] = result_events
      assert event["type"] == "turn.tool_result"
      assert event["payload"]["tool_use_id"] == "tool_abc"
      assert event["payload"]["content"] == "hi\n"
      assert event["payload"]["is_error"] == false
      assert event["seq"] == nil
    end

    test "durable room events are forwarded with seq", %{room_id: room_id, port: port} do
      events = with_sse_client(port, fn ->
        Cranium.RoomEvents.message_created(room_id, %{
          role: "user",
          text: "test message",
          origin: "test",
          epoch_id: "epoch-1"
        })

        Process.sleep(100)
      end)

      durable = filter_events(events, "message.created")
      assert length(durable) >= 1

      [event | _] = durable
      assert is_integer(event["seq"])
      assert event["type"] == "message.created"
    end

    test "ephemeral events do not interfere with durable seq tracking", %{
      room_id: room_id,
      port: port
    } do
      events = with_sse_client(port, fn ->
        Cranium.Events.broadcast(room_id, {:chunk, "s1", "text before"})

        Cranium.RoomEvents.turn_started(room_id, %{stream_id: "s1", epoch_id: "e1"})

        Cranium.Events.broadcast(room_id, {:chunk, "s1", "text after"})

        Cranium.RoomEvents.turn_completed(room_id, %{
          stream_id: "s1",
          epoch_id: "e1",
          turn_count: 1,
          saturation: 0.1
        })

        Process.sleep(100)
      end)

      deltas = filter_events(events, "turn.delta")
      durables = Enum.filter(events, &(&1["type"] in ["turn.started", "turn.completed"]))

      assert length(deltas) >= 2
      assert length(durables) >= 2

      # Durable events should have monotonically increasing seqs
      durable_seqs =
        durables
        |> Enum.map(& &1["seq"])
        |> Enum.reject(&is_nil/1)

      assert durable_seqs == Enum.sort(durable_seqs)
    end
  end

  describe "cursor_expired handling" do
    test "sends cursor_expired when since_seq is older than oldest available event", %{
      room_id: room_id,
      port: port
    } do
      # Emit several events to build up a seq range
      for i <- 1..5 do
        Cranium.Store.emit_room_event(room_id, "test.event", %{i: i})
      end

      # Simulate age-out purge: delete events with seq <= 3 directly
      import Ecto.Query
      Cranium.Store.Repo.delete_all(
        from(e in Cranium.Store.RoomEvent,
          where: e.room_id == ^room_id and e.seq <= 3
        )
      )

      # Now oldest_seq should be 4, and since_seq=2 falls in the gap
      {:ok, oldest_seq} = Cranium.Store.oldest_room_event_seq(room_id)
      assert oldest_seq == 4

      events = with_sse_client(port, fn -> Process.sleep(100) end, since: 2)

      expired = filter_events(events, "cursor_expired")
      assert length(expired) >= 1

      [event | _] = expired
      assert event["type"] == "cursor_expired"
      assert event["payload"]["refresh"] == true
      assert event["seq"] == nil
    end

    test "does not send cursor_expired when since_seq is within available range", %{
      room_id: room_id,
      port: port
    } do
      # Emit an event and use since=0 (fresh client)
      Cranium.Store.emit_room_event(room_id, "test.event", %{i: 1})

      events = with_sse_client(port, fn ->
        Cranium.Store.emit_room_event(room_id, "test.event", %{i: 2})
        Process.sleep(100)
      end, since: 0)

      expired = filter_events(events, "cursor_expired")
      assert expired == []

      # Should have received the regular events instead
      test_events = filter_events(events, "test.event")
      assert length(test_events) >= 1
    end
  end

  # --- Test helpers ---

  # Connect an SSE client, run the given function (which should broadcast
  # events), then collect and return all parsed SSE events.
  defp with_sse_client(port, fun, opts \\ []) do
    collector = self()
    since = Keyword.get(opts, :since, 0)
    url = "http://127.0.0.1:#{port}/events?since=#{since}"

    client_task =
      Task.async(fn ->
        Req.get!(url,
          into: fn {:data, chunk}, {req, resp} ->
            for event <- parse_sse_chunk(chunk) do
              send(collector, {:sse_event, event})
            end

            {:cont, {req, resp}}
          end,
          receive_timeout: 5_000
        )
      end)

    # Wait for SSE connection to establish and EventStream to subscribe
    Process.sleep(100)

    # Run the test body (broadcasts events)
    fun.()

    # Shutdown the client
    Task.shutdown(client_task, :brutal_kill)

    # Collect all received events
    collect_all_events()
  end

  defp parse_sse_chunk(chunk) do
    chunk
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      lines = String.split(block, "\n")
      event_line = Enum.find(lines, &String.starts_with?(&1, "event: "))
      data_line = Enum.find(lines, &String.starts_with?(&1, "data: "))

      if event_line && data_line do
        _event_type = String.trim_leading(event_line, "event: ")
        data = String.trim_leading(data_line, "data: ")

        case Jason.decode(data) do
          {:ok, parsed} -> [parsed]
          _ -> []
        end
      else
        []
      end
    end)
  end

  defp collect_all_events do
    receive do
      {:sse_event, event} -> [event | collect_all_events()]
    after
      100 -> []
    end
  end

  defp filter_events(events, type) do
    Enum.filter(events, &(&1["type"] == type))
  end

  # Minimal Plug that serves the EventStream for testing
  defmodule StreamPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{path_info: ["events"]} = conn, opts) do
      room_id = :persistent_term.get(opts[:room_id_key])
      params = Plug.Conn.fetch_query_params(conn).query_params
      since_seq = String.to_integer(Map.get(params, "since", "0"))
      EventStream.serve(conn, room_id, since_seq)
    end

    def call(conn, _opts) do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end
end
