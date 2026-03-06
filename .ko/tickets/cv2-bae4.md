---
id: cv2-bae4
status: blocked
deps: []
created: 2026-03-05T22:55:49Z
type: task
priority: 2
---
# Segment manifest design: define manifest format for multimedia responses (renditions, cues, growing playlist)

The manifest format is designed (see README.md "Segment Manifest" section). This ticket covers the implementation: a GenServer that tracks segments for active streams and serializes the manifest JSON.

## What to implement

1. Cranium.Manifest GenServer — tracks active streams as %{stream_id => manifest_state}
2. manifest_state holds: status (:streaming | :complete), segments list, conversation_id
3. API: add_utterance(stream_id, index, text), add_cue(stream_id, index, cue_type, data), complete(stream_id), get(stream_id)
4. Segments are utterance (with text rendition always available, audio rendition URL advertised but served lazily from TTS cache) or cue (SCTE marker data)
5. JSON serialization matching the shape in README.md
6. Manifest is ephemeral — lives only while stream is active + a short TTL after completion

## Depends on

Nothing strictly, but integrates with Egress (which populates it) and HTTP transport (which serves it).

## Acceptance criteria

- Manifest.add_utterance/add_cue builds correct segment list
- Manifest.get returns JSON-serializable map matching README spec
- Manifest.complete sets status to :complete
- Tests for all operations

## Notes

**2026-03-06 00:03:40 UTC:** Question: Should the audio rendition include a `duration` field, and if so, how should it be populated before TTS synthesis completes?
Answer: Omit duration field (Recommended)
Audio renditions don't include duration initially; updated via API after TTS synthesis if needed

**2026-03-06 00:03:40 UTC:** Question: How should `conversation_id` be passed to the Manifest?
Answer: Explicit init_stream call (Recommended)
Add `init_stream(stream_id, conversation_id)` for Egress to call on stream start

**2026-03-06 00:07:50 UTC:** ko: FAIL at node 'verify' — node 'verify' failed after 3 attempts: command failed: exit status 2
warning: Git tree '/home/dev/Projects/cranium-v2' is dirty
cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Running ExUnit with seed: 734650, max_cases: 24

...

  1) test synthesize/2 returns {:error, _} on connection error (Cranium.Backend.KokoroTest)
     test/cranium/backend/kokoro_test.exs:30
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.260.0>, CraniumKokoroTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/kokoro_test.exs:31: (test)



  2) test synthesize/2 returns {:ok, audio_binary} on HTTP 200 (Cranium.Backend.KokoroTest)
     test/cranium/backend/kokoro_test.exs:9
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.272.0>, CraniumKokoroTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/kokoro_test.exs:12: (test)



  3) test synthesize/2 returns {:error, {:http_error, 503, _}} on non-200 (Cranium.Backend.KokoroTest)
     test/cranium/backend/kokoro_test.exs:21
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.273.0>, CraniumKokoroTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/kokoro_test.exs:22: (test)

...........................................

  4) test process/2 in :text mode text chunk passes through as %{type: :text} without calling TTS (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:41
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.327.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



  5) test process/2 in :voice mode TTS failure falls back to {:type, :text, data: text} (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:29
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.328.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



  6) test process/2 in :text mode markers pass through unchanged (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:48
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.329.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



  7) test process/2 in :voice mode text chunk is synthesized and returned as audio (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:11
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.330.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



  8) test process/2 in :voice mode markers pass through unchanged without calling TTS (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:22
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.331.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2


00:07:50.884 [info] Manifest registry started

00:07:50.886 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started

00:07:50.887 [info] Manifest registry started


  9) test save_handoff/get_latest_handoff returns the latest handoff when multiple exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:63
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 10) test upsert_epoch inserts then updates, resulting in a single row with updated fields (CraniumTest.StoreTest)
     test/cranium/store_test.exs:41
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 11) test append_message/get_messages returns empty list when no messages exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:33
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 12) test save_summary/get_all_summaries returns all summaries across conversations ordered by most recent (CraniumTest.StoreTest)
     test/cranium/store_test.exs:80
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 13) test upsert_epoch returns :not_found when epoch does not exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:56
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 14) test append_message/get_messages inserts messages and retrieves them in insertion order (CraniumTest.StoreTest)
     test/cranium/store_test.exs:7
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 15) test append_message/get_messages respects the limit option (CraniumTest.StoreTest)
     test/cranium/store_test.exs:20
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 16) test save_handoff/get_latest_handoff returns :not_found when no handoffs exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:73
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2

..........
Finished in 0.1 seconds (0.1s async, 0.02s sync)
72 tests, 16 failures

