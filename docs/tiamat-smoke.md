# Tiamat-backed Cranium smoke path

`crn-319f` added local fake-SSE coverage for the Cranium → Tiamat backend path. Use this document for an optional live smoke against `~/Projects/tiamat`.

## Local automated coverage

From `~/Projects/cranium`, run with the Elixir/Erlang versions declared by the flake:

```bash
ELIXIR=/nix/store/ilra93z02y1yf56jqhnryz7b4rb2sj7p-elixir-1.19.5
ERLANG=/nix/store/sncrwq9cyqmb2z1zbnq2dd7nci03bwq2-erlang-28.4.1
PATH="$ELIXIR/bin:$ERLANG/bin:$PATH" \
  mix test \
    test/cranium/inference/tiamat_turn_request_test.exs \
    test/cranium/backend/llm/tiamat_test.exs \
    test/cranium/backend/llm/tiamat_sse_test.exs \
    test/cranium/backend/llm/tiamat_integration_test.exs
```

The fake SSE tests cover:

- native request assembly with `system_prompt` layers;
- completed `turn_response` handling;
- tool-call response handling;
- normalization-delta application to stored rows;
- Agent-managed tool execution and after-tool-result continuation;
- Tiamat error responses;
- cancellation while the HTTP request is in flight.

## Optional live Tiamat smoke

1. Start Tiamat locally from `~/Projects/tiamat` with whatever profile/backend you want to smoke. The Cranium default expects:

   ```text
   http://localhost:4002/v1/router/turns
   ```

2. Confirm Tiamat has an arm capable of servicing the Cranium router profile you will use. The default Cranium test profile uses `router_profile: exo`; for Claude Code-backed smokes, make sure host Claude auth/install is available.

3. In Cranium, create or select a profile that uses:

   ```yaml
   backend: tiamat
   router_profile: exo
   backend_config:
     endpoint: http://localhost:4002
     timeout: 300000
   ```

4. Send a normal text pass through Cranium using that profile. Expected observations:

   - Cranium logs a `Tiamat request` line with endpoint/profile/message/tool counts.
   - Tiamat receives a `tiamat.turn.request.v1` body with:
     - `session_key: cranium:<conversation_id>:<epoch_id>`;
     - named `system_prompt.pre/post` fragments;
     - native transcript `messages` containing durable Cranium row IDs;
     - Cranium tool definitions unless tools are disabled.
   - Cranium streams returned assistant text to clients.
   - If Tiamat returns a `tool_call`, Cranium executes the tool and sends a second Tiamat request containing the assistant `tool_use` and user `tool_result` messages.
   - `normalization_delta` parent/provenance assignments are applied to persisted rows when selectors resolve.

5. For a cancellation smoke, start a long-running Tiamat-backed turn and cancel it through the normal Cranium cancel path. Expected result: the Agent returns a cancelled partial, Harness emits cancelled pass completion, and the backend HTTP task is terminated.

## Caveats

This is still the v0 adapter path. Cranium owns persistence; Tiamat `normalization_delta` decorates existing request rows, while assistant/tool-result persistence is still performed by Agent/PassReactor after the pass completes.
