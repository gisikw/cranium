---
id: cv2-ede0
status: blocked
deps: []
created: 2026-03-05T22:55:49Z
type: task
priority: 2
---
# STT integration: wire Ingress Transcriber to stt.gisi.network HTTP endpoint, accept audio input and transcribe to text

Cranium v2 Ingress stage has a Transcriber step (lib/cranium/ingress/transcriber.ex) that is currently a stub. Wire it to the Whisper STT HTTP endpoint.

## Whisper endpoint

POST audio to stt.gisi.network/transcribe. Check ~/Projects/cranium/ (v1 source, Go) for the exact request shape — it was wired there for voice message support. The endpoint accepts audio files and returns plain text transcription.

## What to implement

1. Read lib/cranium/ingress/transcriber.ex — stub step module
2. Read lib/cranium/backend/stt.ex — defines the STT behaviour
3. Implement Cranium.Backend.STT.Whisper to POST audio binary to stt.gisi.network/transcribe, return {:ok, text}
4. Wire Transcriber to call STT backend when event type is :audio
5. Pass-through for :text events (no transcription needed)

## Acceptance criteria

- Cranium.Backend.STT.Whisper.transcribe(audio_binary) returns {:ok, "transcribed text"}
- Ingress correctly routes audio events through transcription
- Tests for the backend (mock HTTP)

## Notes

**2026-03-06 00:02:32 UTC:** Question: What filename should be used for the audio file in the multipart form-data request to stt.gisi.network?
Answer: Simple placeholder 'audio' (Recommended)
Use a bare filename without extension; let the endpoint infer audio format from binary content

**2026-03-06 00:10:04 UTC:** ko: FAIL at node 'verify' — node 'verify' failed after 3 attempts: command failed: exit status 2
warning: Git tree '/home/dev/Projects/cranium-v2' is dirty
cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Running ExUnit with seed: 332463, max_cases: 24

...

  1) test transcribe/2 returns {:ok, text} on HTTP 200 with text (Cranium.Backend.WhisperTest)
     test/cranium/backend/whisper_test.exs:9
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.271.0>, CraniumWhisperTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/whisper_test.exs:10: (test)



  2) test synthesize/2 returns {:ok, audio_binary} on HTTP 200 (Cranium.Backend.KokoroTest)
     test/cranium/backend/kokoro_test.exs:9
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.264.0>, CraniumKokoroTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/kokoro_test.exs:12: (test)



  3) test transcribe/2 returns {:error, _} on connection error (Cranium.Backend.WhisperTest)
     test/cranium/backend/whisper_test.exs:49
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.282.0>, CraniumWhisperTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/whisper_test.exs:50: (test)



  4) test synthesize/2 returns {:error, _} on connection error (Cranium.Backend.KokoroTest)
     test/cranium/backend/kokoro_test.exs:30
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.283.0>, CraniumKokoroTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/kokoro_test.exs:31: (test)



  5) test transcribe/2 returns {:error, {:http_error, 503, _}} on non-200 (Cranium.Backend.WhisperTest)
     test/cranium/backend/whisper_test.exs:40
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.284.0>, CraniumWhisperTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/whisper_test.exs:41: (test)



  6) test transcribe/2 returns {:error, {:stt_error, reason}} when response contains error field (Cranium.Backend.WhisperTest)
     test/cranium/backend/whisper_test.exs:29
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.286.0>, CraniumWhisperTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/whisper_test.exs:30: (test)



  7) test transcribe/2 trims whitespace from transcription (Cranium.Backend.WhisperTest)
     test/cranium/backend/whisper_test.exs:19
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.287.0>, CraniumWhisperTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/whisper_test.exs:20: (test)



  8) test synthesize/2 returns {:error, {:http_error, 503, _}} on non-200 (Cranium.Backend.KokoroTest)
     test/cranium/backend/kokoro_test.exs:21
     ** (exit) exited in: GenServer.call(Req.Test.Ownership, {:get_and_update, #PID<0.285.0>, CraniumKokoroTest, #Function<3.28971161/1 in Req.Test.stub/2>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     code: Req.Test.stub(@plug_name, fn conn ->
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (req 0.5.17) lib/req/test/ownership.ex:59: Req.Test.Ownership.get_and_update/5
       (req 0.5.17) lib/req/test.ex:541: Req.Test.stub/2
       test/cranium/backend/kokoro_test.exs:22: (test)

...........................................

  9) test process/2 in :voice mode text chunk is synthesized and returned as audio (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:11
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.338.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



 10) test process/2 in :text mode markers pass through unchanged (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:48
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.339.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



 11) test process/2 in :text mode text chunk passes through as %{type: :text} without calling TTS (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:41
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.340.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



 12) test process/2 in :voice mode TTS failure falls back to {:type, :text, data: text} (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:29
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.341.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2



 13) test process/2 in :voice mode markers pass through unchanged without calling TTS (Cranium.Egress.SynthesizerTest)
     test/cranium/egress/synthesizer_test.exs:22
     ** (exit) exited in: GenServer.call({:global, Mox.Server}, {:set_owner_to_manual_cleanup, #PID<0.342.0>}, 5000)
         ** (EXIT) no process: the process is not alive or there's no process currently associated with the given name, possibly because its application isn't started
     stacktrace:
       (elixir 1.18.4) lib/gen_server.ex:1121: GenServer.call/3
       (mox 1.2.0) lib/mox.ex:816: Mox.verify_on_exit!/1
       test/cranium/egress/synthesizer_test.exs:1: Cranium.Egress.SynthesizerTest.__ex_unit__/2


00:10:04.480 [info] Manifest registry started

00:10:04.483 [info] Manifest registry started

00:10:04.483 [info] Manifest registry started

00:10:04.483 [info] Manifest registry started

00:10:04.483 [info] Manifest registry started

00:10:04.483 [info] Manifest registry started

00:10:04.483 [info] Manifest registry started

00:10:04.484 [info] Manifest registry started

00:10:04.484 [info] Manifest registry started

00:10:04.484 [info] Manifest registry started


 14) test append_message/get_messages inserts messages and retrieves them in insertion order (CraniumTest.StoreTest)
     test/cranium/store_test.exs:7
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 15) test upsert_epoch returns :not_found when epoch does not exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:56
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 16) test save_handoff/get_latest_handoff returns the latest handoff when multiple exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:63
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 17) test save_handoff/get_latest_handoff returns :not_found when no handoffs exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:73
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 18) test save_summary/get_all_summaries returns all summaries across conversations ordered by most recent (CraniumTest.StoreTest)
     test/cranium/store_test.exs:80
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 19) test upsert_epoch inserts then updates, resulting in a single row with updated fields (CraniumTest.StoreTest)
     test/cranium/store_test.exs:41
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 20) test append_message/get_messages returns empty list when no messages exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:33
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2



 21) test append_message/get_messages respects the limit option (CraniumTest.StoreTest)
     test/cranium/store_test.exs:20
     ** (MatchError) no match of right hand side value: {:error, {%RuntimeError{message: "could not lookup Ecto repo Cranium.Store.Repo because it was not started or it does not exist"}, [{Ecto.Repo.Registry, :lookup, 1, [file: ~c"lib/ecto/repo/registry.ex", line: 22, error_info: %{module: Exception}]}, {Ecto.Adapters.SQL.Sandbox, :lookup_meta!, 1, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 640]}, {Ecto.Adapters.SQL.Sandbox, :checkout, 2, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 544]}, {Ecto.Adapters.SQL.Sandbox, :"-start_owner!/2-fun-0-", 3, [file: ~c"lib/ecto/adapters/sql/sandbox.ex", line: 454]}, {Agent.Server, :init, 1, [file: ~c"lib/agent/server.ex", line: 8]}, {:gen_server, :init_it, 2, [file: ~c"gen_server.erl", line: 2229]}, {:gen_server, :init_it, 6, [file: ~c"gen_server.erl", line: 2184]}, {:proc_lib, :init_p_do_apply, 3, [file: ~c"proc_lib.erl", line: 329]}]}}
     stacktrace:
       (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:451: Ecto.Adapters.SQL.Sandbox.start_owner!/2
       (cranium 0.1.0) test/support/data_case.ex:11: CraniumTest.DataCase.__ex_unit_setup_0/1
       (cranium 0.1.0) test/support/data_case.ex:1: CraniumTest.DataCase.__ex_unit__/2
       test/cranium/store_test.exs:1: CraniumTest.StoreTest.__ex_unit__/2

..........
Finished in 0.1 seconds (0.1s async, 0.02s sync)
77 tests, 21 failures

