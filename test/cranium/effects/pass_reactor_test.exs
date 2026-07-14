defmodule Cranium.Effects.PassReactorTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.Effects.PassReactor

  defp flush_effects, do: GenServer.call(PassReactor, :flush)

  describe "pass_complete (success)" do
    test "persists assistant message and updates epoch state" do
      conversation_id = "test-effects-#{System.unique_integer([:positive])}"

      # Create epoch
      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      # Simulate pass_complete from Harness
      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "hello world",
           saturation: 0.5,
           turn_count: 1,
           cc_session_id: "cc-123",
           ephemeral: false
         }}
      )

      flush_effects()

      # Verify assistant message was persisted
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)

      assert Enum.any?(messages, fn m ->
               m.role == :assistant and Cranium.Store.extract_text(m.content) == "hello world"
             end)

      # Verify epoch state was updated
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.saturation == 0.5
      assert epoch.turn_count == 1
      assert epoch.cc_session_id == "cc-123"
      assert epoch.interrupted_context == nil
      assert epoch.status == "active"
    end

    test "emits message.created with message_id and full TranscriptMessage projection" do
      conversation_id = "test-effects-msg-event-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "hello world",
           saturation: 0.5,
           turn_count: 1,
           cc_session_id: nil,
           origin: "test",
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      [persisted] = Enum.filter(messages, &(&1.role == :assistant))

      {:ok, events} = Cranium.Store.list_room_events(conversation_id, 0)
      assert [event] = Enum.filter(events, &(&1.type == "message.created"))

      assert event.payload["message_id"] == persisted.id
      assert event.payload["preview"] == "hello world"
      assert event.payload["role"] == "assistant"

      message = event.payload["message"]
      assert message["id"] == persisted.id
      assert message["room_id"] == conversation_id
      assert message["text"] == "hello world"
      assert [%{"type" => "text", "text" => "hello world", "id" => part_id}] = message["parts"]
      assert part_id == "#{persisted.id}:0"
    end

    test "strips suppressed spans before persistence and journals them" do
      conversation_id = "test-effects-suppress-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      journal =
        Path.join(
          System.tmp_dir!(),
          "cranium-suppression-#{System.unique_integer([:positive])}.jsonl"
        )

      paths_before = Application.get_env(:cranium, :paths, [])

      Application.put_env(
        :cranium,
        :paths,
        Keyword.put(paths_before, :suppression_journal, journal)
      )

      on_exit(fn ->
        Application.put_env(:cranium, :paths, paths_before)
        File.rm(journal)
      end)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "Public.\n\n<suppressed>private note</suppressed>\n\nMore.",
           saturation: 0.1,
           turn_count: 1,
           cc_session_id: nil,
           ephemeral: false
         }}
      )

      flush_effects()

      # Stored history sees only the stripped text, whitespace collapsed
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      [stored] = Enum.filter(messages, &(&1.role == :assistant))
      assert Cranium.Store.extract_text(stored.content) == "Public.\n\nMore."

      # The room event fan-out sees the stripped text too
      {:ok, events} = Cranium.Store.list_room_events(conversation_id, 0)
      [event] = Enum.filter(events, &(&1.type == "message.created"))
      refute inspect(event.payload) =~ "private note"

      # The journal has the span, timestamped and room-labeled
      [line] = journal |> File.read!() |> String.split("\n", trim: true)
      entry = Jason.decode!(line)
      assert entry["room"] == conversation_id
      assert entry["epoch_id"] == ctx.epoch_id
      assert entry["content"] == "private note"
      assert {:ok, _dt, 0} = DateTime.from_iso8601(entry["at"])
    end

    test "skips Store mutations for ephemeral passes" do
      conversation_id = "test-effects-eph-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "ephemeral output",
           saturation: 0.3,
           turn_count: 1,
           cc_session_id: "cc-456",
           ephemeral: true
         }}
      )

      flush_effects()

      # Verify no message was persisted
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      # Verify epoch state was NOT updated
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.turn_count == 0
    end

    test "skips message persistence for empty output" do
      conversation_id = "test-effects-empty-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "",
           saturation: 0.1,
           turn_count: 1,
           cc_session_id: nil,
           ephemeral: false
         }}
      )

      flush_effects()

      # No assistant message (empty output)
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      # But epoch state still updated
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.turn_count == 1
    end
  end

  describe "pass_complete (cancelled)" do
    test "persists partial output and stores interrupted context" do
      conversation_id = "test-effects-cancel-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :cancelled,
           epoch_id: ctx.epoch_id,
           output: "partial output here",
           cc_session_id: "cc-789",
           ephemeral: false
         }}
      )

      flush_effects()

      # Verify partial message was persisted
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)

      assert Enum.any?(messages, fn m ->
               m.role == :assistant and
                 Cranium.Store.extract_text(m.content) == "partial output here"
             end)

      # Verify interrupted_context was stored
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.interrupted_context == "partial output here"
      assert epoch.cc_session_id == "cc-789"
    end

    test "truncates long interrupted context to 2000 chars" do
      conversation_id = "test-effects-trunc-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)
      long_output = String.duplicate("x", 3000)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :cancelled,
           epoch_id: ctx.epoch_id,
           output: long_output,
           cc_session_id: nil,
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert String.length(epoch.interrupted_context) < 3000
      assert String.ends_with?(epoch.interrupted_context, "[...output truncated...]")
    end

    test "stores interrupted context even when cancelled output is empty" do
      conversation_id = "test-effects-cancel-context-only-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :cancelled,
           epoch_id: ctx.epoch_id,
           output: "",
           interrupted_context: "> **bash**: `hostname`",
           cc_session_id: nil,
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.interrupted_context == "> **bash**: `hostname`"
    end

    test "handles empty partial output on cancel" do
      conversation_id = "test-effects-cancel-empty-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :cancelled,
           epoch_id: ctx.epoch_id,
           output: "",
           cc_session_id: nil,
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.interrupted_context == nil
    end
  end

  describe "pass_complete (error)" do
    test "resets epoch status to active" do
      conversation_id = "test-effects-error-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      # Set status to inferring first
      Cranium.Store.update_epoch(ctx.epoch_id, %{status: "inferring"})

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-1",
         %{
           reason: :error,
           epoch_id: ctx.epoch_id,
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.status == "active"
    end

    test "persists intermediate messages, partial output, and interrupted context" do
      conversation_id = "test-effects-error-partial-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      intermediate_messages = [
        %{
          role: "assistant",
          content: [%{"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => %{}}]
        },
        %{
          role: "user",
          content: [%{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "/tmp"}]
        }
      ]

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-err-partial",
         %{
           reason: :error,
           epoch_id: ctx.epoch_id,
           error: "{:error, %Req.TransportError{reason: :timeout}}",
           output: "partial text before failure",
           intermediate_messages: intermediate_messages,
           cc_session_id: "cc-err-1",
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, messages} = Cranium.Store.get_messages(conversation_id)

      # Intermediates persisted in order
      assert Enum.any?(messages, fn m ->
               m.role == :assistant and
                 Enum.any?(m.content, &(&1["type"] == "tool_use" and &1["id"] == "toolu_1"))
             end)

      assert Enum.any?(messages, fn m ->
               m.role == :user and
                 Enum.any?(m.content, &(&1["type"] == "tool_result"))
             end)

      # Partial output persisted as assistant message
      assert Enum.any?(messages, fn m ->
               m.role == :assistant and
                 Cranium.Store.extract_text(m.content) == "partial text before failure"
             end)

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.status == "active"
      assert epoch.interrupted_context == "partial text before failure"
      assert epoch.cc_session_id == "cc-err-1"
    end

    test "drops trailing assistant intermediate without a tool_result" do
      conversation_id = "test-effects-error-orphan-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      intermediate_messages = [
        %{
          role: "assistant",
          content: [%{"type" => "tool_use", "id" => "toolu_9", "name" => "bash", "input" => %{}}]
        }
      ]

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-err-orphan",
         %{
           reason: :error,
           epoch_id: ctx.epoch_id,
           error: "timeout",
           output: "",
           intermediate_messages: intermediate_messages,
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)
    end

    test "preserves prior interrupted_context and cc_session_id when error carries none" do
      conversation_id = "test-effects-error-preserve-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      Cranium.Store.update_epoch(ctx.epoch_id, %{
        status: "inferring",
        interrupted_context: "breadcrumb from earlier cancel",
        cc_session_id: "cc-existing"
      })

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-err-preserve",
         %{
           reason: :error,
           epoch_id: ctx.epoch_id,
           error: "timeout before first token",
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.status == "active"
      assert epoch.interrupted_context == "breadcrumb from earlier cancel"
      assert epoch.cc_session_id == "cc-existing"
    end

    test "emits turn.errored room event with error detail" do
      conversation_id = "test-effects-error-detail-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(
        PassReactor,
        {:pass_complete, conversation_id, "stream-err",
         %{
           reason: :error,
           epoch_id: ctx.epoch_id,
           error: "{:http_error, 500, \"upstream exploded\"}",
           ephemeral: false
         }}
      )

      flush_effects()

      {:ok, events} = Cranium.Store.list_room_events(conversation_id, 0)
      assert [event] = Enum.filter(events, &(&1.type == "turn.errored"))
      assert event.payload["stream_id"] == "stream-err"
      assert event.payload["epoch_id"] == ctx.epoch_id
      assert event.payload["error"] == "{:http_error, 500, \"upstream exploded\"}"
    end
  end

  describe "pass_done signaling" do
    test "signals pass_done to TurnAssembler after successful pass" do
      conversation_id = "test-effects-passdone-#{System.unique_integer([:positive])}"
      stream_id = "stream-pd-1"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      # Register test process as TurnAssembler
      Registry.register(
        Cranium.Inference.ConversationRegistry,
        {conversation_id, :turn_assembler},
        []
      )

      send(
        PassReactor,
        {:pass_complete, conversation_id, stream_id,
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "done",
           saturation: 0.1,
           turn_count: 1,
           cc_session_id: nil,
           ephemeral: false
         }}
      )

      assert_receive {:pass_done, ^stream_id}, 1000
    end

    test "signals pass_done even for ephemeral passes" do
      conversation_id = "test-effects-passdone-eph-#{System.unique_integer([:positive])}"
      stream_id = "stream-pd-2"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      Registry.register(
        Cranium.Inference.ConversationRegistry,
        {conversation_id, :turn_assembler},
        []
      )

      send(
        PassReactor,
        {:pass_complete, conversation_id, stream_id,
         %{
           reason: :complete,
           epoch_id: ctx.epoch_id,
           output: "",
           saturation: 0.0,
           turn_count: 1,
           cc_session_id: nil,
           ephemeral: true
         }}
      )

      assert_receive {:pass_done, ^stream_id}, 1000
    end
  end
end
