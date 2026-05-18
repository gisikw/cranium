defmodule Cranium.TestPlugins.Echo do
  @moduledoc "Test plugin that injects an echo tag at priority 25."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    {:ok, [:before_context_build], %{call_count: 0}}
  end

  @impl true
  def before_context_build(_turn_context, state) do
    state = %{state | call_count: state.call_count + 1}
    injection = %{priority: 25, content: "<echo>echo-#{state.call_count}</echo>"}
    {:ok, [injection], state}
  end
end

defmodule Cranium.TestPlugins.Skipper do
  @moduledoc "Test plugin that always returns :skip."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    {:ok, [:before_context_build], %{}}
  end

  @impl true
  def before_context_build(_turn_context, state) do
    {:ok, :skip, state}
  end
end

defmodule Cranium.TestPlugins.Ignorer do
  @moduledoc "Test plugin that declines to participate."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    :ignore
  end

  @impl true
  def before_context_build(_turn_context, state) do
    {:ok, :skip, state}
  end
end

defmodule Cranium.TestPlugins.Crasher do
  @moduledoc "Test plugin that raises in before_context_build."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    {:ok, [:before_context_build], %{}}
  end

  @impl true
  def before_context_build(_turn_context, _state) do
    raise "intentional crash"
  end
end

defmodule Cranium.TestPlugins.EpochEndTracker do
  @moduledoc "Test plugin that tracks on_epoch_end calls via the test process."
  @behaviour Cranium.Plugin

  @impl true
  def init(metadata) do
    {:ok, [:on_epoch_end], %{test_pid: metadata.plugin_config["test_pid"]}}
  end

  @impl true
  def on_epoch_end(context, state) do
    send(state.test_pid, {:epoch_end_called, context})
    :ok
  end
end

defmodule Cranium.TestPlugins.EpochEndCrasher do
  @moduledoc "Test plugin that raises in on_epoch_end."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    {:ok, [:on_epoch_end], %{}}
  end

  @impl true
  def on_epoch_end(_context, _state) do
    raise "intentional epoch_end crash"
  end
end

defmodule Cranium.TestPlugins.MultiInjector do
  @moduledoc "Test plugin that injects multiple items at different priorities."
  @behaviour Cranium.Plugin

  @impl true
  def init(metadata) do
    {:ok, [:before_context_build], %{config: metadata.plugin_config}}
  end

  @impl true
  def before_context_build(_turn_context, state) do
    injections = [
      %{priority: 5, content: "<early>before-everything</early>"},
      %{priority: 35, content: "<late>between-saturation-and-interrupted</late>"}
    ]
    {:ok, injections, state}
  end
end

defmodule Cranium.TestPlugins.ProfileSwapper do
  @moduledoc "Test plugin that overrides model and backend in after_resolve_profile."
  @behaviour Cranium.Plugin

  @impl true
  def init(metadata) do
    overrides = metadata.plugin_config || %{}
    {:ok, [:after_resolve_profile], %{overrides: overrides}}
  end

  @impl true
  def after_resolve_profile(context, state) do
    new_context = Map.merge(context, state.overrides)
    {:ok, new_context, state}
  end
end

defmodule Cranium.TestPlugins.ProfilePassthrough do
  @moduledoc "Test plugin that subscribes to after_resolve_profile but returns context unchanged."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    {:ok, [:after_resolve_profile], %{call_count: 0}}
  end

  @impl true
  def after_resolve_profile(context, state) do
    {:ok, context, %{state | call_count: state.call_count + 1}}
  end
end

defmodule Cranium.TestPlugins.ProfileCrasher do
  @moduledoc "Test plugin that raises in after_resolve_profile."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    {:ok, [:after_resolve_profile], %{}}
  end

  @impl true
  def after_resolve_profile(_context, _state) do
    raise "intentional profile crash"
  end
end

defmodule Cranium.TestPlugins.ToolProvider do
  @moduledoc "Test plugin that declares tools and handles tool calls."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    tools = [
      %{
        name: "greet",
        description: "Generate a greeting",
        input_schema: %{
          type: "object",
          properties: %{name: %{type: "string"}},
          required: ["name"]
        }
      },
      %{
        name: "farewell",
        description: "Say goodbye",
        input_schema: %{type: "object", properties: %{}}
      }
    ]

    {:ok, [:before_context_build], tools, %{calls: []}}
  end

  @impl true
  def before_context_build(_turn_context, state) do
    {:ok, :skip, state}
  end

  @impl true
  def handle_tool_call(%{tool_name: "greet", input: input}, state) do
    name = Map.get(input, "name", "world")
    state = %{state | calls: [{:greet, name} | state.calls]}
    {:ok, ~s({"greeting": "Hello, #{name}!"}), state}
  end

  def handle_tool_call(%{tool_name: "farewell"}, state) do
    state = %{state | calls: [{:farewell} | state.calls]}
    {:ok, ~s({"farewell": "Goodbye!"}), state}
  end

  def handle_tool_call(%{tool_name: name}, state) do
    {:error, "unknown tool: #{name}", state}
  end
end

defmodule Cranium.TestPlugins.ToolCrasher do
  @moduledoc "Test plugin whose handle_tool_call raises."
  @behaviour Cranium.Plugin

  @impl true
  def init(_metadata) do
    tools = [
      %{name: "boom", description: "Always crashes", input_schema: %{type: "object"}}
    ]

    {:ok, [], tools, %{}}
  end

  @impl true
  def handle_tool_call(_context, _state) do
    raise "intentional tool crash"
  end
end

defmodule Cranium.TestPlugins.EpochStartTracker do
  @moduledoc "Test plugin that tracks on_epoch_start calls via the test process."
  @behaviour Cranium.Plugin

  @impl true
  def init(metadata) do
    {:ok, [:on_epoch_start], %{test_pid: metadata.plugin_config["test_pid"]}}
  end

  @impl true
  def on_epoch_start(context, state) do
    send(state.test_pid, {:epoch_start_called, context})
    {:ok, state}
  end
end
