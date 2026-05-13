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
