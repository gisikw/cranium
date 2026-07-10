defmodule Cranium.Store.SuppressionJournalTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Cranium.Store.SuppressionJournal

  defp with_journal_path(path) do
    paths_before = Application.get_env(:cranium, :paths, [])
    Application.put_env(:cranium, :paths, Keyword.put(paths_before, :suppression_journal, path))

    on_exit(fn ->
      Application.put_env(:cranium, :paths, paths_before)
      if is_binary(path), do: File.rm(path)
    end)
  end

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "cranium-suppression-journal-#{System.unique_integer([:positive])}.jsonl"
    )
  end

  test "appends one greppable JSONL entry per span" do
    path = tmp_path()
    with_journal_path(path)

    assert :ok = SuppressionJournal.append("room-a", 42, ["first thought", "second\nthought"])

    [line1, line2] = path |> File.read!() |> String.split("\n", trim: true)

    entry1 = Jason.decode!(line1)
    assert entry1["room"] == "room-a"
    assert entry1["epoch_id"] == 42
    assert entry1["content"] == "first thought"
    assert {:ok, _dt, 0} = DateTime.from_iso8601(entry1["at"])

    assert Jason.decode!(line2)["content"] == "second\nthought"
  end

  test "appends across calls without truncating" do
    path = tmp_path()
    with_journal_path(path)

    :ok = SuppressionJournal.append("room-a", 1, ["one"])
    :ok = SuppressionJournal.append("room-b", 2, ["two"])

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
    assert Jason.decode!(Enum.at(lines, 1))["room"] == "room-b"
  end

  test "no spans is a no-op" do
    path = tmp_path()
    with_journal_path(path)

    assert :ok = SuppressionJournal.append("room-a", 1, [])
    refute File.exists?(path)
  end

  test "nil path disables journaling" do
    with_journal_path(nil)
    assert :ok = SuppressionJournal.append("room-a", 1, ["lost but stripped"])
  end

  test "write failure still returns :ok (privacy beats trace)" do
    # a directory is not writable as a file
    dir =
      Path.join(
        System.tmp_dir!(),
        "cranium-suppression-dir-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rmdir(dir) end)
    with_journal_path(dir)

    assert :ok = SuppressionJournal.append("room-a", 1, ["span"])
  end
end
