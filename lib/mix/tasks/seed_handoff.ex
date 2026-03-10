defmodule Mix.Tasks.SeedHandoff do
  @shortdoc "Seed a handoff for a conversation from a file"

  @moduledoc """
  Inserts a handoff document into the Store for a given conversation ID.

  Used to bootstrap a v2 conversation with context from a v1 handoff.

      mix seed_handoff hearth /path/to/handoff.md

  The next fresh epoch for that conversation will pick up the handoff
  via TurnInjector on turn 1.
  """

  use Mix.Task

  @impl Mix.Task
  def run([conversation_id, file_path]) do
    Mix.Task.run("app.start")

    case File.read(file_path) do
      {:ok, content} ->
        Cranium.Store.save_handoff(conversation_id, String.trim(content))
        Mix.shell().info("Seeded handoff for #{conversation_id} (#{byte_size(content)} bytes)")

      {:error, reason} ->
        Mix.shell().error("Failed to read #{file_path}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix seed_handoff <conversation_id> <handoff_file>")
    exit({:shutdown, 1})
  end
end
