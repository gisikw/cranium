defmodule Cranium.Context.Router do
  @moduledoc """
  Routing utilities for mapping conversations to project directories.

  Pure functions used by Epoch, HandoffWriter, and ConversationSummarizer.
  Will move to Transport when Transport actors exist.
  """

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
