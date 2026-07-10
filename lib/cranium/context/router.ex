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
  Resolve a working directory for a conversation.

  If the conversation matches a project under `projects_dir`, returns that
  project path. Otherwise, returns a temp directory at `/tmp/cranium/<slug>`
  (created if it doesn't exist) so non-project conversations don't inherit
  cranium's own workdir.
  """
  @spec resolve_working_dir(String.t(), String.t()) :: String.t()
  def resolve_working_dir(conversation_id, projects_dir) do
    case resolve_project_dir(conversation_id, projects_dir) do
      nil ->
        slug = slugify(conversation_id)
        tmp = Path.join("/tmp/cranium", slug)
        File.mkdir_p!(tmp)
        tmp

      dir ->
        dir
    end
  end

  @doc """
  Working directory for a remote-exec room: `<projects_dir>/<slug>` on the
  REMOTE host's filesystem.

  Purely textual — no existence check, no creation. The local checks in
  `resolve_working_dir/2` are meaningless here (the path lives on another
  box), and a wrong guess surfaces as a tool error from the remote muse
  rather than a silent local `/tmp` fallback.
  """
  @spec remote_working_dir(String.t(), String.t()) :: String.t()
  def remote_working_dir(conversation_id, projects_dir) do
    Path.join(projects_dir, slugify(conversation_id))
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
