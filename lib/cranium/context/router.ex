defmodule Cranium.Context.Router do
  @moduledoc """
  Maps conversations to working directories and project context.

  Given a conversation name (e.g., "nerve"), checks if a matching directory
  exists under the configured projects path. If so, the epoch runs in that
  directory, giving the agent access to project-specific files,
  INVARIANTS.md, etc.

  Also determines whether this is a fresh epoch or a resumed one,
  which affects downstream context assembly.
  """

  @spec process(map(), map()) :: {:ok, map()}
  def process(message, context) do
    conversation_id = message.conversation_id
    projects_dir = Map.get(context, :projects_dir, "~/Projects")

    working_dir = resolve_project_dir(conversation_id, projects_dir)
    epoch_state = Cranium.Store.get_epoch(conversation_id)

    is_fresh =
      case epoch_state do
        :not_found -> true
        {:ok, %{turn_count: 0}} -> true
        _ -> false
      end

    enriched =
      Map.merge(message, %{
        working_dir: working_dir,
        epoch_state: epoch_state,
        is_fresh: is_fresh
      })

    {:ok, enriched}
  end

  @doc """
  Resolve a conversation name to a project directory, if one exists.
  """
  @spec resolve_project_dir(String.t(), String.t()) :: String.t() | nil
  def resolve_project_dir(conversation_id, projects_dir) do
    slug = slugify(conversation_id)
    expanded = Path.expand(projects_dir)
    candidate = Path.join(expanded, slug)

    if File.dir?(candidate), do: candidate, else: nil
  end

  @doc """
  Convert a conversation ID or name to a filesystem-safe slug.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
