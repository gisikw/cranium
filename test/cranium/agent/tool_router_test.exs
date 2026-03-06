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
      assert {:execute, __MODULE__, %{"key" => "val"}} = ToolRouter.route(%{name: "my_tool", input: %{"key" => "val"}})
    end
  end
end
