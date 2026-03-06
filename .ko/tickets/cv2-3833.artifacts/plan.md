## Goal

Implement real tool dispatch: define a `Tool` behaviour, add runtime-registered lookup to `ToolRouter`, and replace the stub in `ToolExecutor` with actual module dispatch.

## Context

- `lib/cranium/agent/tool_router.ex`: `route/1` handles marker tools but returns `{:unknown, name}` for all others. Return type `{:execute, module(), map()}` is already declared — the lookup is just a TODO. `requires_approval?/1` is also a stub (always false).
- `lib/cranium/agent/tool_executor.ex`: `execute/3` runs in an async Task with timeout. `do_execute/3` is a stub returning a JSON error string. Public API is `execute(String.t(), map(), keyword())`.
- `lib/cranium/agent/marker_emitter.ex`: Complete — no changes needed.
- `lib/cranium/agent/harness.ex`: Helper for single-turn inference — not touched by this ticket.
- `lib/cranium/agent.ex`: Agent loop's `receive_loop` has `{:llm_tool_use, _tool_call}` and `{:llm_stop, "tool_use"}` stubs — wiring these is the job of downstream ticket cv2-89f0 (deps: cv2-3833), not this one.
- Backend pattern: backends are registered in `config/config.exs` under `config :cranium, :backends, [...]`. Same pattern documents the key but tools use runtime registration for test isolation.
- No existing tests for `ToolRouter` or `ToolExecutor`.

## Approach

Add a `Cranium.Agent.Tool` behaviour with required `execute/2` and optional `name/0` callbacks. Add `ToolRouter.register/2` for runtime registration backed by `Application.put_env` (enables test isolation). Update `ToolRouter.route/1` to look up the runtime registry. Update `ToolExecutor` to dispatch to the resolved module, changing its public signature from `(String.t(), map(), keyword())` to `(module(), map(), keyword())`, logging via `module.name()` if exported or `inspect(module)` otherwise.

## Tasks

1. **[lib/cranium/agent/tool.ex] — Create `Tool` behaviour.**
   Define `Cranium.Agent.Tool` with required callback `execute(input :: map(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}` and optional callback `name() :: String.t()` via `@optional_callbacks`. No other logic.
   Verify: `mix compile --warnings-as-errors` passes.

2. **[config/config.exs] — Add tool registry config key.**
   Add `config :cranium, :tools, []` under the backends config block. Documents the key; tools are registered at runtime via `ToolRouter.register/2`.
   Verify: `mix compile` still passes.

3. **[lib/cranium/agent/tool_router.ex] — Add `register/2` and implement registry lookup.**
   Add `register(name, module)` that calls `Application.put_env(:cranium, :tools, [{name, module} | existing])`. Replace the `true ->` branch's `{:unknown, name}` stub with a private `find_handler/1` that reads `Application.get_env(:cranium, :tools, [])`, looks up `name`, returns `{:execute, module, input}` if found, `{:unknown, name}` otherwise. No changes to `@marker_tools` or `requires_approval?/1`.
   Verify: `mix compile --warnings-as-errors` passes.

4. **[lib/cranium/agent/tool_executor.ex] — Implement `do_execute` dispatch, update public API.**
   Change `execute/3` signature from `(String.t(), map(), keyword())` to `(module(), map(), keyword())`. Update typespec. In `do_execute/3`, call `module.execute(input, opts)`. Log using `module.name()` if `function_exported?(module, :name, 0)`, otherwise `inspect(module)`. Keep `Task.async` + `Task.yield` timeout wrapper and `truncate_result/1` unchanged.
   Verify: `mix compile --warnings-as-errors` passes.

5. **[test/cranium/agent/tool_router_test.exs] — Add ToolRouter tests.**
   Test with `async: true`:
   - Marker tool (e.g., `"show"`) routes to `{:marker, :show, input}`.
   - Unknown tool name returns `{:unknown, "nonexistent"}`.
   - Registered tool: use `ToolRouter.register/2` in setup (restore original env in on_exit) and assert `route(%{name: "my_tool", input: %{}})` returns `{:execute, MyTestModule, %{}}`.
   Verify: `mix test test/cranium/agent/tool_router_test.exs` passes.

6. **[test/cranium/agent/tool_executor_test.exs] — Add ToolExecutor tests.**
   Test with `async: true` using inline modules implementing `Cranium.Agent.Tool`:
   - Successful dispatch: module returns `{:ok, "result"}`, assert `execute(module, %{}, [])` returns `{:ok, "result"}`.
   - Error passthrough: module returns `{:error, :oops}`, assert result is `{:error, :oops}`.
   - Timeout: module sleeps longer than timeout opt, assert result is `{:error, :tool_timeout}`.
   - Truncation: `truncate_result/1` with >50k string returns truncated string ending in `"\n... (truncated)"`.
   Verify: `mix test test/cranium/agent/tool_executor_test.exs` passes.
   Final verify: `mix test --no-start` passes (ignoring pre-existing store_test failure).

## Open Questions

None — both questions answered in ticket notes:
1. **Registration**: Runtime via `ToolRouter.register/2` (cleaner test isolation).
2. **Logging**: Optional `name/0` callback on Tool behaviour.
