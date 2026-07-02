defmodule Cranium.Inference.Agent.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Cranium.Inference.Agent.ToolExecutor

  defmodule OkTool do
    @behaviour Cranium.Inference.Agent.Tool

    @impl true
    def execute(_input, _opts), do: {:ok, "result"}

    @impl true
    def name, do: "ok_tool"
  end

  defmodule ErrorTool do
    @behaviour Cranium.Inference.Agent.Tool

    @impl true
    def execute(_input, _opts), do: {:error, :oops}
  end

  defmodule SlowTool do
    @behaviour Cranium.Inference.Agent.Tool

    @impl true
    def execute(_input, _opts) do
      Process.sleep(500)
      {:ok, "slow result"}
    end
  end

  describe "execute/3" do
    test "dispatches to tool module and returns result" do
      assert {:ok, "result"} = ToolExecutor.execute(OkTool, %{}, [])
    end

    test "passes through error results" do
      assert {:error, :oops} = ToolExecutor.execute(ErrorTool, %{}, [])
    end

    test "returns timeout error when tool exceeds timeout" do
      assert {:error, :tool_timeout} = ToolExecutor.execute(SlowTool, %{}, timeout: 50)
    end
  end

  describe "truncate_result/1" do
    test "passes through short strings unchanged" do
      assert ToolExecutor.truncate_result("short") == "short"
    end

    test "truncates strings exceeding max size" do
      long = String.duplicate("a", 60_000)
      result = ToolExecutor.truncate_result(long)
      assert String.ends_with?(result, "\n... (truncated)")
      assert byte_size(result) < byte_size(long)
    end

    test "leaves oversize content envelopes intact" do
      envelope =
        Jason.encode!(%{
          "type" => "content",
          "content" => [
            %{"type" => "text", "text" => "screenshot.png: image/png"},
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => Base.encode64(:crypto.strong_rand_bytes(60_000))
              }
            }
          ]
        })

      assert byte_size(envelope) > 50_000
      assert ToolExecutor.truncate_result(envelope) == envelope
    end

    test "still truncates oversize legacy JSON objects" do
      legacy = Jason.encode!(%{"content" => String.duplicate("a", 60_000)})
      result = ToolExecutor.truncate_result(legacy)
      assert String.ends_with?(result, "\n... (truncated)")
      assert byte_size(result) < byte_size(legacy)
    end
  end
end
