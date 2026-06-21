defmodule Cranium.Backend.LLM.TiamatIntegrationTest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Backend.LLM.Tiamat
  alias Cranium.Inference.Agent

  @moduletag :capture_log

  defmodule TestRouter do
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/v1/router/turns"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      {:ok, request} = Jason.decode(body)
      send(test_pid(), {:tiamat_request, request})

      response = response_for(request)

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(
        200,
        "event: turn_response\ndata: #{Jason.encode!(response)}\n\nevent: done\ndata: {}\n\n"
      )
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp response_for(request) do
      messages = request["messages"] || []

      if Enum.any?(messages, &tool_result_message?/1) do
        %{
          "schema" => "tiamat.turn.response.v1",
          "response_id" => Ecto.UUID.generate(),
          "request_id" => request["request_id"],
          "status" => "completed",
          "usage" => %{"input_tokens" => 20, "output_tokens" => 5},
          "transcript_delta" => [
            %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "tool result observed"}]
            }
          ]
        }
      else
        %{
          "schema" => "tiamat.turn.response.v1",
          "response_id" => Ecto.UUID.generate(),
          "request_id" => request["request_id"],
          "status" => "tool_call",
          "transcript_delta" => [
            %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "checking"},
                %{
                  "type" => "tool_use",
                  "tool_use_id" => "toolu_echo",
                  "tool_name" => "echo",
                  "tool_input" => %{"msg" => "from tiamat"}
                }
              ]
            }
          ]
        }
      end
    end

    defp tool_result_message?(%{"content" => content}) when is_list(content) do
      Enum.any?(content, &(Map.get(&1, "type") == "tool_result"))
    end

    defp tool_result_message?(_), do: false

    defp test_pid do
      :persistent_term.get({__MODULE__, :test_pid})
    end
  end

  setup do
    :persistent_term.put({TestRouter, :test_pid}, self())

    port = 46_000 + :rand.uniform(5_000)
    {:ok, server} = Bandit.start_link(plug: TestRouter, port: port)

    tools_before = Application.get_env(:cranium, :tools, [])
    Cranium.Inference.Agent.ToolRouter.register("echo", __MODULE__.EchoTool)

    on_exit(fn ->
      Application.put_env(:cranium, :tools, tools_before)
      :persistent_term.erase({TestRouter, :test_pid})
      Process.exit(server, :shutdown)
    end)

    %{endpoint: "http://127.0.0.1:#{port}"}
  end

  test "Tiamat-backed Agent turn executes tool calls and continues with tool_result history", %{
    endpoint: endpoint
  } do
    conversation_id = "tiamat-agent-#{System.unique_integer([:positive])}"
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

    :ok =
      Cranium.Store.append_message(conversation_id, epoch_id, %{
        role: :user,
        content: [%{"type" => "text", "text" => "use echo"}],
        origin: "test"
      })

    stream_id = "s-tiamat-tool-loop"
    Cranium.Events.subscribe({:stream_raw, stream_id})

    {:ok, agent} = Agent.start_link(conversation_id: conversation_id, llm_backend: Tiamat)

    result =
      Agent.infer(agent, %{
        conversation_id: conversation_id,
        epoch_id: epoch_id,
        router_profile: "exo",
        stream_id: stream_id,
        system: "Flattened fallback prompt",
        system_prompt_pre: [%{"id" => "cranium-identity", "text" => "General identity"}],
        system_prompt_post: [%{"id" => "cranium-tools", "text" => "Tool guidance"}],
        messages: [%{role: "user", content: [%{"type" => "text", "text" => "use echo"}]}],
        backend_config: %{"endpoint" => endpoint, "timeout" => 5_000}
      })

    assert {:ok, %{status: :complete, output: "tool result observed"} = payload} = result
    assert payload.final_message_content == [%{type: "text", text: "tool result observed"}]

    assert_receive {:tiamat_request, first_request}

    assert first_request["system_prompt"] == %{
             "pre" => [%{"id" => "cranium-identity", "text" => "General identity"}],
             "post" => [%{"id" => "cranium-tools", "text" => "Tool guidance"}]
           }

    refute Enum.any?(first_request["messages"], &tool_result_message?/1)

    assert_receive {:tiamat_request, second_request}
    assert Enum.any?(second_request["messages"], &assistant_tool_use_message?/1)
    assert Enum.any?(second_request["messages"], &tool_result_message?/1)

    assert [assistant_tool_message] =
             Enum.filter(second_request["messages"], &assistant_tool_use_message?/1)

    assert [tool_use_block] =
             Enum.filter(assistant_tool_message["content"], &(Map.get(&1, "type") == "tool_use"))

    assert tool_use_block["tool_use_id"] == "toolu_echo"
    assert tool_use_block["tool_name"] == "echo"
    assert tool_use_block["tool_input"] == %{"msg" => "from tiamat"}
    refute Map.has_key?(tool_use_block, "id")
    refute Map.has_key?(tool_use_block, "name")
    refute Map.has_key?(tool_use_block, "input")

    assert [tool_result_message] = Enum.filter(second_request["messages"], &tool_result_message?/1)

    assert [tool_result_block] =
             Enum.filter(tool_result_message["content"], &(Map.get(&1, "type") == "tool_result"))

    assert tool_result_block["tool_result_for"] == "toolu_echo"
    assert is_binary(tool_result_block["tool_output"])
    refute Map.has_key?(tool_result_block, "tool_use_id")
    refute Map.has_key?(tool_result_block, "content")

    assert_receive {:chunk, ^stream_id, "checking"}
    assert_receive {:chunk, ^stream_id, {:tool_use, %{id: "toolu_echo", name: "echo"}}}

    assert_receive {:chunk, ^stream_id,
                    {:tool_result, %{tool_use_id: "toolu_echo", content: content}}}

    assert content =~ "from tiamat"
  end

  defp tool_result_message?(%{"content" => content}) when is_list(content) do
    Enum.any?(content, &(Map.get(&1, "type") == "tool_result"))
  end

  defp tool_result_message?(_), do: false

  defp assistant_tool_use_message?(%{"role" => "assistant", "content" => content})
       when is_list(content) do
    Enum.any?(content, &(Map.get(&1, "type") == "tool_use"))
  end

  defp assistant_tool_use_message?(_), do: false

  defmodule EchoTool do
    @behaviour Cranium.Inference.Agent.Tool

    @impl true
    def execute(input, _opts), do: {:ok, Jason.encode!(input)}

    @impl true
    def name, do: "echo"

    @impl true
    def schema do
      %{
        name: "echo",
        description: "Echoes the input back as JSON",
        input_schema: %{type: "object", properties: %{msg: %{type: "string"}}}
      }
    end
  end
end
