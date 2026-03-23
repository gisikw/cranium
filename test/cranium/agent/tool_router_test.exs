defmodule Cranium.Agent.ToolRouterTest.TestTool do
  @behaviour Cranium.Agent.Tool

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

defmodule Cranium.Agent.ToolRouterTest do
  use ExUnit.Case, async: true

  alias Cranium.Agent.ToolRouter

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
    test "includes marker tool definitions" do
      defs = ToolRouter.tool_definitions()
      names = Enum.map(defs, & &1.name)
      assert "show" in names
      assert "show_code" in names
      assert "play_audio" in names
    end

    test "includes registered tool schemas" do
      original = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, original) end)

      ToolRouter.register("test_tool", Cranium.Agent.ToolRouterTest.TestTool)
      defs = ToolRouter.tool_definitions()
      names = Enum.map(defs, & &1.name)
      assert "test_tool" in names

      tool_def = Enum.find(defs, &(&1.name == "test_tool"))
      assert tool_def.description == "A test tool"
    end
  end
end
