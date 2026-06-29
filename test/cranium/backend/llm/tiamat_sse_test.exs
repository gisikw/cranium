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

      case mode() do
        :block ->
          send(self_pid(), :tiamat_request_blocking)
          Process.sleep(:infinity)
          conn

        :error ->
          response = %{
            "schema" => "tiamat.turn.response.v1",
            "response_id" => Ecto.UUID.generate(),
            "request_id" => request["request_id"],
            "status" => "error",
            "error_code" => "invalid_request",
            "errors" => [
              %{
                "code" => "invalid_request",
                "message" => "bad fake request",
                "recoverable" => false
              }
            ]
          }

          send_sse(conn, response)

        :completed ->
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
            "normalization_delta" => %{
              "assignments" => [
                %{
                  "selector" => %{"index" => 0},
                  "assigned" => %{
                    "parent_id" => nil,
                    "provenance" => %{"normalized_by" => "tiamat-test"}
                  }
                }
              ]
            },
            "routing_diagnostics" => %{"attempts" => []}
          }

          send_sse(conn, response)

        :native ->
          response = %{
            "schema" => "tiamat.turn.response.v1",
            "response_id" => Ecto.UUID.generate(),
            "request_id" => request["request_id"],
            "status" => "tool_call",
            "transcript_delta" => [
              %{
                "role" => "assistant",
                "content" => [
                  %{"type" => "text", "text" => "streamed text"},
                  %{
                    "type" => "tool_use",
                    "tool_use_id" => "toolu_native",
                    "tool_name" => "bash",
                    "tool_input" => %{"command" => "printf native"}
                  }
                ]
              }
            ],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
          }

          send_native_sse(conn, request, response)

        :retrospective_native ->
          response = %{
            "schema" => "tiamat.turn.response.v1",
            "response_id" => Ecto.UUID.generate(),
            "request_id" => request["request_id"],
            "status" => "completed",
            "transcript_delta" => [
              %{
                "role" => "assistant",
                "content" => [%{"type" => "text", "text" => "completed text"}]
              }
            ]
          }

          send_retrospective_native_sse(conn, request, response)

        :mismatched_text_part_replay ->
          response = native_text_replay_response(request)

          send_text_replay_native_sse(conn, request, response, %{
            "attempt_id" => "att_1",
            "message_id" => "msg_1",
            "part_id" => "part_completed_different",
            "index" => 0,
            "content_type" => "text",
            "completion_status" => "completed",
            "content" => %{"type" => "text", "text" => "streamed text"}
          })

        :missing_text_part_replay ->
          response = native_text_replay_response(request)

          send_text_replay_native_sse(conn, request, response, %{
            "attempt_id" => "att_1",
            "message_id" => "msg_1",
            "index" => 0,
            "content_type" => "text",
            "completion_status" => "completed",
            "content" => %{"type" => "text", "text" => "streamed text"}
          })
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp send_sse(conn, response) do
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(
        200,
        "event: turn_response\ndata: #{Jason.encode!(response)}\n\nevent: done\ndata: {}\n\n"
      )
    end

    defp send_native_sse(conn, request, response) do
      events = [
        native_event(request, 1, "turn_started", %{
          "received_at" => "2026-06-23T22:19:04.123Z",
          "router_profile" => request["router_profile"]
        }),
        native_event(request, 2, "content_part_delta", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_1",
          "content_type" => "text",
          "delta" => %{"text" => "streamed "}
        }),
        native_event(request, 3, "content_part_delta", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_1",
          "content_type" => "text",
          "delta" => %{"text" => "text"}
        }),
        native_event(request, 4, "content_part_completed", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_1",
          "index" => 0,
          "content_type" => "text",
          "completion_status" => "completed",
          "content" => %{"type" => "text", "text" => "streamed text"}
        }),
        native_event(request, 5, "content_part_completed", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_2",
          "index" => 1,
          "content_type" => "tool_use",
          "completion_status" => "completed",
          "content" => %{
            "type" => "tool_use",
            "tool_use_id" => "toolu_native",
            "tool_name" => "bash",
            "tool_input" => %{"command" => "printf native"}
          }
        }),
        native_event(request, 6, "assistant_message_completed", %{
          "attempt_id" => "att_1",
          "message" => %{
            "id" => "msg_1",
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "streamed text"},
              %{
                "type" => "tool_use",
                "tool_use_id" => "toolu_native",
                "tool_name" => "bash",
                "tool_input" => %{"command" => "printf native"}
              }
            ]
          },
          "completion_status" => "completed"
        }),
        native_event(request, 7, "usage_update", %{
          "attempt_id" => "att_1",
          "reporting_mode" => "final",
          "final" => true,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
        }),
        native_event(request, 8, "turn_response", %{"response" => response}),
        native_event(request, 9, "stream_closed", %{"status" => "closed"})
      ]

      send_native_events(conn, events)
    end

    defp send_retrospective_native_sse(conn, request, response) do
      events = [
        native_event(request, 1, "turn_started", %{
          "received_at" => "2026-06-23T22:19:04.123Z",
          "router_profile" => request["router_profile"]
        }),
        native_event(request, 2, "content_part_started", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_1",
          "index" => 0,
          "content_type" => "text",
          "initial" => %{"text" => ""}
        }),
        native_event(request, 3, "content_part_completed", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_1",
          "index" => 0,
          "content_type" => "text",
          "completion_status" => "completed",
          "content" => %{"type" => "text", "text" => "completed text"}
        }),
        native_event(request, 4, "turn_response", %{"response" => response}),
        native_event(request, 5, "stream_closed", %{"status" => "closed"})
      ]

      send_native_events(conn, events)
    end

    defp native_text_replay_response(request) do
      %{
        "schema" => "tiamat.turn.response.v1",
        "response_id" => Ecto.UUID.generate(),
        "request_id" => request["request_id"],
        "status" => "completed",
        "transcript_delta" => [
          %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "streamed text"}]
          }
        ]
      }
    end

    defp send_text_replay_native_sse(conn, request, response, completed_payload) do
      events = [
        native_event(request, 1, "turn_started", %{
          "received_at" => "2026-06-23T22:19:04.123Z",
          "router_profile" => request["router_profile"]
        }),
        native_event(request, 2, "content_part_delta", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_delta",
          "content_type" => "text",
          "delta" => %{"text" => "streamed "}
        }),
        native_event(request, 3, "content_part_delta", %{
          "attempt_id" => "att_1",
          "message_id" => "msg_1",
          "part_id" => "part_delta",
          "content_type" => "text",
          "delta" => %{"text" => "text"}
        }),
        native_event(request, 4, "content_part_completed", completed_payload),
        native_event(request, 5, "turn_response", %{"response" => response}),
        native_event(request, 6, "stream_closed", %{"status" => "closed"})
      ]

      send_native_events(conn, events)
    end

    defp send_native_events(conn, events) do
      body =
        events
        |> Enum.map(fn event -> "data: #{Jason.encode!(event)}\n\n" end)
        |> IO.iodata_to_binary()

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, body)
    end

    defp native_event(request, sequence, type, payload) do
      %{
        "schema" => "tiamat.turn.event.v1",
        "event_id" => "evt_#{sequence}",
        "request_id" => request["request_id"],
        "sequence" => sequence,
        "type" => type,
        "payload" => payload
      }
    end

    defp self_pid do
      :persistent_term.get({__MODULE__, :test_pid})
    end

    defp mode do
      :persistent_term.get({__MODULE__, :mode}, :completed)
    end
  end

  setup do
    :persistent_term.put({TestRouter, :test_pid}, self())
    :persistent_term.put({TestRouter, :mode}, :completed)

    {:ok, server} = Bandit.start_link(plug: TestRouter, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      :persistent_term.erase({TestRouter, :test_pid})
      :persistent_term.erase({TestRouter, :mode})
      Process.exit(server, :shutdown)
    end)

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

    assert request["system_prompt"]["post"] == []

    assert [%{"role" => "user"}] = request["messages"]
    assert request["tools"] == []

    assert_receive {:llm_text, "from tiamat"}
    assert_receive {:llm_stop, "end_turn"}

    {:ok, [stored]} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)
    assert stored.provenance == %{"normalized_by" => "tiamat-test"}

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :noproc]
  end

  test "does not transiently duplicate persisted latest user from in-memory tail", %{
    endpoint: endpoint
  } do
    conversation_id = "tiamat-sse-dedupe-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    user_content = [%{"type" => "text", "text" => "latest user"}]

    :ok =
      Cranium.Store.append_message(conversation_id, epoch_id, %{
        role: :user,
        content: user_content,
        origin: "test"
      })

    in_memory_messages = [
      %{role: :system, content: [%{"type" => "text", "text" => "in-memory-only prelude"}]},
      %{role: :user, content: user_content}
    ]

    assert {:ok, _pid} =
             Tiamat.stream_chat(in_memory_messages,
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, request}
    assert [%{"role" => "user", "content" => ^user_content}] = request["messages"]
    refute_receive {:tiamat_request, _}, 50
  end

  test "consumes native Tiamat turn stream events incrementally", %{endpoint: endpoint} do
    :persistent_term.put({TestRouter, :mode}, :native)

    conversation_id = "tiamat-native-sse-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    assert {:ok, _pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, _request}
    assert_receive {:llm_text, "streamed "}
    assert_receive {:llm_text, "text"}

    assert_receive {:llm_assistant_content,
                    [
                      %{
                        "type" => "tool_use",
                        "tool_use_id" => "toolu_native",
                        "tool_name" => "bash",
                        "tool_input" => %{"command" => "printf native"}
                      }
                    ]}

    assert_receive {:llm_tool_use,
                    %{id: "toolu_native", name: "bash", input: %{"command" => "printf native"}}}

    assert_receive {:llm_usage, %{input_tokens: 5, output_tokens: 2}}
    assert_receive {:llm_stop, "tool_use"}
    refute_receive {:llm_tool_use, %{id: "toolu_native"}}, 50
    refute_receive {:llm_text, "streamed text"}, 50
  end

  test "suppresses completed text replay when completed part id differs after text deltas", %{
    endpoint: endpoint
  } do
    :persistent_term.put({TestRouter, :mode}, :mismatched_text_part_replay)

    conversation_id = "tiamat-mismatched-text-replay-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    assert {:ok, _pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, _request}
    assert_receive {:llm_text, "streamed "}
    assert_receive {:llm_text, "text"}
    assert_receive {:llm_stop, "end_turn"}
    refute_receive {:llm_text, "streamed text"}, 50
  end

  test "suppresses completed text replay when completed part id is missing after text deltas", %{
    endpoint: endpoint
  } do
    :persistent_term.put({TestRouter, :mode}, :missing_text_part_replay)

    conversation_id = "tiamat-missing-text-replay-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    assert {:ok, _pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, _request}
    assert_receive {:llm_text, "streamed "}
    assert_receive {:llm_text, "text"}
    assert_receive {:llm_stop, "end_turn"}
    refute_receive {:llm_text, "streamed text"}, 50
  end

  test "emits completed text parts when no text deltas streamed for the part", %{
    endpoint: endpoint
  } do
    :persistent_term.put({TestRouter, :mode}, :retrospective_native)

    conversation_id = "tiamat-retrospective-native-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    assert {:ok, _pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, _request}
    assert_receive {:llm_text, "completed text"}
    assert_receive {:llm_assistant_content, [%{"type" => "text", "text" => "completed text"}]}
    assert_receive {:llm_stop, "end_turn"}
    refute_receive {:llm_text, "completed text"}, 50
  end

  test "translates Tiamat SSE error responses", %{endpoint: endpoint} do
    :persistent_term.put({TestRouter, :mode}, :error)

    conversation_id = "tiamat-sse-error-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    assert {:ok, _pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
             )

    assert_receive {:tiamat_request, _request}

    assert_receive {:llm_stop,
                    {:error,
                     %{
                       error_code: "invalid_request",
                       errors: [
                         %{
                           "code" => "invalid_request",
                           "message" => "bad fake request",
                           "recoverable" => false
                         }
                       ]
                     }}}
  end

  test "backend process can be cancelled while HTTP request is in flight", %{endpoint: endpoint} do
    :persistent_term.put({TestRouter, :mode}, :block)

    conversation_id = "tiamat-sse-cancel-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    assert {:ok, pid} =
             Tiamat.stream_chat([],
               conversation_id: conversation_id,
               epoch_id: epoch_id,
               router_profile: "exo",
               tools_disabled: true,
               backend_config: %{"endpoint" => endpoint, "timeout" => 60_000}
             )

    assert_receive {:tiamat_request, _request}
    assert_receive :tiamat_request_blocking

    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 2_000
    refute_receive {:llm_stop, _}, 50
  end
end
