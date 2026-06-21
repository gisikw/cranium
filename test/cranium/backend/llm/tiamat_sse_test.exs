defmodule Cranium.Backend.LLM.TiamatSSETest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Backend.LLM.Tiamat

  defmodule TestRouter do
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/v1/router/turns"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      {:ok, request} = Jason.decode(body)
      send(self_pid(), {:tiamat_request, request})

      response = %{
        "schema" => "tiamat.turn.response.v1",
        "response_id" => Ecto.UUID.generate(),
        "request_id" => request["request_id"],
        "status" => "completed",
        "transcript_delta" => [
          %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "from tiamat"}]
          }
        ],
        "normalization_delta" => %{"assignments" => []},
        "routing_diagnostics" => %{"attempts" => []}
      }

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(
        200,
        "event: turn_response\ndata: #{Jason.encode!(response)}\n\nevent: done\ndata: {}\n\n"
      )
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp self_pid do
      :persistent_term.get({__MODULE__, :test_pid})
    end
  end

  setup do
    :persistent_term.put({TestRouter, :test_pid}, self())

    port = 45_000 + :rand.uniform(10_000)
    {:ok, _} = Bandit.start_link(plug: TestRouter, port: port)

    on_exit(fn -> :persistent_term.erase({TestRouter, :test_pid}) end)

    %{endpoint: "http://127.0.0.1:#{port}"}
  end

  test "posts a native Tiamat request and translates SSE response", %{endpoint: endpoint} do
    conversation_id = "tiamat-sse-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    :ok =
      Cranium.Store.append_message(conversation_id, epoch_id, %{
        role: :user,
        content: [%{"type" => "text", "text" => "hello"}],
        origin: "test"
      })

    assert {:ok, pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               system: "System prompt",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, request}
    assert request["router_profile"] == "exo"
    assert request["session_key"] == "cranium:#{conversation_id}:#{epoch_id}"

    assert request["system_prompt"]["pre"] == [
             %{"id" => "cranium-system", "text" => "System prompt"}
           ]

    assert [%{"role" => "user"}] = request["messages"]
    assert request["tools"] == []

    assert_receive {:llm_text, "from tiamat"}
    assert_receive {:llm_stop, "end_turn"}

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :noproc]
  end
end
