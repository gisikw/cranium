defmodule Cranium.Inference.Agent.ToolRouterTest.TestTool do
  @behaviour Cranium.Inference.Agent.Tool

  @impl true
  def execute(_input, _opts), do: {:ok, "test"}

  @impl true
  def name, do: "test_tool"

  @impl true
  def schema do
    %{
      name: "test_tool",
      description: "A test tool",
      input_schema: %{type: "object", properties: %{}}
    }
  end
end

defmodule Cranium.Inference.Agent.ToolRouterTest do
  use ExUnit.Case, async: true

  alias Cranium.Inference.Agent.ToolRouter

  describe "route/1" do
    test "routes marker tools to {:marker, atom, input}" do
      result = ToolRouter.route(%{name: "show", input: %{"text" => "hello"}})
      assert {:marker, :show, %{"text" => "hello"}} = result
    end

    test "returns {:unknown, name} for unregistered tools" do
      assert {:unknown, "nonexistent"} = ToolRouter.route(%{name: "nonexistent", input: %{}})
    end

    test "routes registered tools to {:execute, module, input}" do
      original = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, original) end)

      ToolRouter.register("my_tool", __MODULE__)

      assert {:execute, __MODULE__, %{"key" => "val"}} =
               ToolRouter.route(%{name: "my_tool", input: %{"key" => "val"}})
    end
  end

  describe "tool_definitions/0" do
    test "includes clear_context meta-tool" do
      defs = ToolRouter.tool_definitions()
      names = Enum.map(defs, & &1.name)
      assert "clear_context" in names
    end

    test "omits registered tools from advertised set (temporary lockdown)" do
      original = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, original) end)

      ToolRouter.register("test_tool", Cranium.Inference.Agent.ToolRouterTest.TestTool)
      defs = ToolRouter.tool_definitions()
      names = Enum.map(defs, & &1.name)
      refute "test_tool" in names
    end
  end
end
