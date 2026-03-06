## Goal

Implement real tool dispatch: define a `Tool` behaviour, add registry-based lookup to `ToolRouter`, and replace the stub in `ToolExecutor` with actual module dispatch.

## Context

- `lib/cranium/agent/tool_router.ex`: `route/1` handles marker tools but returns `{:unknown, name}` for all others. Return type `{:execute, module(), map()}` is already declared — the lookup is just a TODO. `requires_approval?/1` is also a stub (always false).
- `lib/cranium/agent/tool_executor.ex`: `execute/3` runs in an async Task with timeout. `do_execute/3` is a stub returning a JSON error string. Public API is `execute(String.t(), map(), keyword())`.
- `lib/cranium/agent/marker_emitter.ex`: Complete — no changes needed.
- `lib/cranium/agent/harness.ex`: Helper for single-turn inference — not touched by this ticket.
- `lib/cranium/agent.ex`: Agent loop's `receive_loop` has `{:llm_tool_use, _tool_call}` and `{:llm_stop, "tool_use"}` stubs — wiring these is the job of downstream ticket cv2-89f0 (deps: cv2-3833), not this one.
- Backend pattern: backends are registered in `config/config.exs` under `config :cranium, :backends, [...]`. Same pattern applies here for tool registration.
- No existing tests for `ToolRouter` or `ToolExecutor`.

## Approach

Add a `Cranium.Agent.Tool` behaviour that tool handler modules implement. Register tools in application config (`config :cranium, :tools, []`) as `{name_string, module}` pairs. Update `ToolRouter.route/1` to look up the config registry. Update `ToolExecutor` to dispatch to the resolved module, changing its public signature from `(String.t(), map(), keyword())` to `(module(), map(), keyword())` to match ToolRouter's existing `{:execute, module(), map()}` return type.

## Tasks

1. **[lib/cranium/agent/tool.ex] — Create `Tool` behaviour.**
   Define `Cranium.Agent.Tool` with one callback: `@callback execute(input :: map(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}`. No other logic — this is the contract tool handler modules must satisfy.
   Verify: `mix compile --warnings-as-errors` passes.

2. **[config/config.exs] — Add tool registry config key.**
   Add `config :cranium, :tools, []` under the backends config block. This documents the key and establishes the pattern (empty list = no real tools registered yet).
   Verify: `mix compile` still passes; `Application.get_env(:cranium, :tools)` returns `[]` in tests.

3. **[lib/cranium/agent/tool_router.ex:route/1] — Implement registry lookup.**
   Replace the `true ->` branch's `{:unknown, name}` stub with: read `Application.get_env(:cranium, :tools, [])`, look up `name` in the list, return `{:execute, module, input}` if found, `{:unknown, name}` otherwise. Extract the lookup into a private `find_handler/1` for readability. No changes to the `@marker_tools` list or `requires_approval?/1` (that's cv2-18d2).
   Verify: `mix compile --warnings-as-errors` passes.

4. **[lib/cranium/agent/tool_executor.ex] — Implement `do_execute` dispatch, update public API.**
   Change `execute/3` signature from `(String.t(), map(), keyword())` to `(module(), map(), keyword())`. Update the typespec accordingly. In `do_execute/3`, call `module.execute(input, opts)` directly. Keep the `Task.async` + `Task.yield` timeout wrapper and `Logger.info` (log `inspect(module)` instead of tool_name). Keep `truncate_result/1` unchanged.
   Verify: `mix compile --warnings-as-errors` passes.

5. **[test/cranium/agent/tool_router_test.exs] — Add ToolRouter tests.**
   Test three cases with `async: true`:
   - Marker tool (e.g., `"show"`) routes to `{:marker, :show, input}`.
   - Unknown tool name returns `{:unknown, "nonexistent"}`.
   - Registered tool: temporarily put a test module into application env (`Application.put_env(:cranium, :tools, [{"my_tool", MyTestModule}])` in setup, restore in on_exit) and assert `route(%{name: "my_tool", input: %{}})` returns `{:execute, MyTestModule, %{}}`.
   Verify: `mix test test/cranium/agent/tool_router_test.exs` passes.

6. **[test/cranium/agent/tool_executor_test.exs] — Add ToolExecutor tests.**
   Test three cases with `async: true` using a simple inline module (or anonymous module trick) that implements `Cranium.Agent.Tool`:
   - Successful dispatch: define a module returning `{:ok, "result"}`, assert `execute(module, %{}, [])` returns `{:ok, "result"}`.
   - Error passthrough: define a module returning `{:error, :oops}`, assert result is `{:error, :oops}`.
   - Timeout: define a module that sleeps longer than the timeout opt, assert result is `{:error, :tool_timeout}`.
   - Truncation: `truncate_result/1` with >50k string returns truncated string ending in "... (truncated)".
   Verify: `mix test test/cranium/agent/tool_executor_test.exs` passes.
   Final verify: `mix test --no-start` all 35+ tests pass.

## Open Questions

1. **Tool registration mechanism**: Config-based (`Application.get_env`) is consistent with backends but means tool list is fixed at startup. A runtime registration function (`ToolRouter.register/2`) would allow dynamic registration and cleaner test isolation. The config approach is simpler and consistent with existing patterns — proceeding with config unless directed otherwise.

2. **ToolExecutor public API change**: Changing `execute/3` from `(String.t(), map(), keyword())` to `(module(), map(), keyword())` matches the ToolRouter route result but is a breaking change. Since there are no callers yet (cv2-89f0 will be the first), this is safe — but the module to log for observability is `inspect(module)` rather than a tool name string. If a human-readable tool name is important for logs, the signature could be `(module(), map(), keyword())` with the module also implementing a `name/0` callback.
