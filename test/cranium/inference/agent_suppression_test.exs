defmodule Cranium.Inference.AgentSuppressionTest do
  use CraniumTest.DataCase, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  @conversation_id "test-agent-suppression"

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)

    journal =
      Path.join(
        System.tmp_dir!(),
        "cranium-agent-suppression-#{System.unique_integer([:positive])}.jsonl"
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

    {:ok, journal: journal}
  end

  defp start_agent do
    {:ok, pid} = Cranium.Inference.Agent.start_link(conversation_id: @conversation_id)
    pid
  end

  defp expect_stream(chunks) do
    Cranium.Backend.LLM.Mock
    |> expect(:stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn(fn ->
          Enum.each(chunks, &send(caller, &1))
          send(caller, {:llm_stop, "end_turn"})
        end)

      {:ok, pid}
    end)
  end

  defp infer(stream_id) do
    Cranium.Events.subscribe({:stream_raw, stream_id})
    agent = start_agent()

    Cranium.Inference.Agent.infer(agent, %{
      messages: [%{role: "user", content: "test"}],
      stream_id: stream_id,
      epoch_id: 7
    })
  end

  # Drain every text chunk broadcast for the stream, in order.
  defp collect_text_chunks(stream_id, acc \\ []) do
    receive do
      {:chunk, ^stream_id, data} when is_binary(data) ->
        collect_text_chunks(stream_id, acc ++ [data])

      {:chunk, ^stream_id, _other} ->
        collect_text_chunks(stream_id, acc)

      {:stream_start, ^stream_id, _} ->
        collect_text_chunks(stream_id, acc)

      {:stream_end, ^stream_id} ->
        acc
    after
      1_000 -> acc
    end
  end

  defp read_journal(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "a span split across stream chunks never reaches any broadcast", %{journal: journal} do
    expect_stream([
      {:llm_text, "Public part <supp"},
      {:llm_text, "ressed>private "},
      {:llm_text, "thought</suppres"},
      {:llm_text, "sed> and more."}
    ])

    {:ok, result} = infer("s-sup-split")

    assert result.output == "Public part and more."

    chunks = collect_text_chunks("s-sup-split")
    assert Enum.join(chunks) == "Public part and more."
    refute Enum.any?(chunks, &(&1 =~ "private"))

    assert [entry] = read_journal(journal)
    assert entry["room"] == @conversation_id
    assert entry["epoch_id"] == 7
    assert entry["content"] == "private thought"
    assert {:ok, _dt, 0} = DateTime.from_iso8601(entry["at"])
  end

  test "an unclosed span fails closed: stripped to end of message, journaled", %{
    journal: journal
  } do
    expect_stream([
      {:llm_text, "Answer.\n\n<suppressed>never "},
      {:llm_text, "closed"}
    ])

    {:ok, result} = infer("s-sup-unclosed")

    assert result.output == "Answer."
    refute Enum.join(collect_text_chunks("s-sup-unclosed")) =~ "never closed"

    assert [entry] = read_journal(journal)
    assert entry["content"] == "never closed"
  end

  test "a fully suppressed message yields silence, not the empty-response placeholder", %{
    journal: journal
  } do
    expect_stream([{:llm_text, "<suppressed>all hidden</suppressed>"}])

    {:ok, result} = infer("s-sup-all")

    assert result.output == ""
    chunks = collect_text_chunks("s-sup-all")
    assert chunks == []

    assert [entry] = read_journal(journal)
    assert entry["content"] == "all hidden"
  end

  test "native assistant content blocks are stripped without double-journaling", %{
    journal: journal
  } do
    expect_stream([
      {:llm_text, "Hi <suppressed>sec</suppressed>there"},
      {:llm_assistant_content,
       [%{"type" => "text", "text" => "Hi <suppressed>sec</suppressed>there"}]}
    ])

    {:ok, result} = infer("s-sup-blocks")

    assert result.output == "Hi there"
    assert result.final_message_content == [%{type: "text", text: "Hi there"}]

    assert [entry] = read_journal(journal)
    assert entry["content"] == "sec"
  end

  test "messages without spans pass through untouched", %{journal: journal} do
    expect_stream([{:llm_text, "Plain answer with a < sign.\n"}])

    {:ok, result} = infer("s-sup-none")

    assert result.output == "Plain answer with a < sign.\n"
    assert Enum.join(collect_text_chunks("s-sup-none")) == "Plain answer with a < sign.\n"
    refute File.exists?(journal)
  end
end
