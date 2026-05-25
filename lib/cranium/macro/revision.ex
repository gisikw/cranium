defmodule Cranium.Macro.Revision do
  @moduledoc """
  Macro definition self-modification at epoch end.

  When a macro has revision=session_end and was active during the epoch,
  dispatches an async revision prompt to a sidecar model. If the model
  returns an update, atomically rewrites the macro's JSON definition file,
  bumps the version, and triggers a Registry reload.

  Follows the glossary plugin's revision pattern: fire-and-forget Task.start,
  atomic tmp+rename file write, sidecar model call via Ollama.
  """

  require Logger

  alias Cranium.Macro.{Registry, Definition}

  @doc """
  Dispatch async revision for a macro definition.

  Called from Engine.on_epoch_end/1. Receives the full epoch_end_context
  including messages. Fire-and-forget — revision runs in a background task.
  """
  @spec dispatch(Definition.t(), map()) :: :ok
  def dispatch(macro, epoch_end_context) do
    unless macro.revision_config do
      Logger.warning("Macro.Revision: #{macro.name} has revision=session_end but no revision_config")
      :ok
    else
      messages = epoch_end_context[:messages] || []
      source_path = macro.source_path

      unless source_path do
        Logger.warning("Macro.Revision: #{macro.name} has no source_path, cannot revise")
        :ok
      else
        # Capture everything needed before spawning
        revision_config = macro.revision_config
        macro_name = macro.name
        current_version = macro.version || 0
        sidecar_model = macro.sidecar_config && macro.sidecar_config.model

        Task.start(fn ->
          case run_revision(macro_name, revision_config, messages, sidecar_model, source_path, current_version) do
            {:ok, :no_update} ->
              Logger.info("Macro.Revision: #{macro_name} — no update needed")

            {:ok, :updated} ->
              Logger.info("Macro.Revision: #{macro_name} — definition updated, version bumped")
              # Reload registry to pick up the new definition
              Registry.reload()

            {:error, reason} ->
              Logger.warning("Macro.Revision: #{macro_name} failed: #{inspect(reason)}")
          end
        end)

        :ok
      end
    end
  end

  # --- Private ---

  defp run_revision(macro_name, revision_config, messages, sidecar_model, source_path, current_version) do
    # Read current definition from disk
    with {:ok, current_json} <- File.read(source_path),
         {:ok, current_def} <- Jason.decode(current_json) do
      # Build the revision prompt
      definition_text = Jason.encode!(current_def, pretty: true)

      messages_text =
        messages
        |> Enum.map_join("\n", fn msg ->
          role = msg[:role] || msg["role"] || "unknown"
          content = msg[:content] || msg["content"] || ""
          "#{role}: #{content}"
        end)

      prompt =
        revision_config.prompt
        |> String.replace("%{definition}", definition_text)
        |> String.replace("%{messages}", messages_text)

      # Call sidecar model
      {model, endpoint} = resolve_sidecar(sidecar_model)

      body = %{
        model: model,
        messages: [%{role: "user", content: prompt}],
        stream: false,
        format: "json"
      }

      case Req.post("#{endpoint}/api/chat",
             json: body,
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          handle_revision_response(resp, source_path, current_def, current_version, macro_name)

        {:ok, %{status: status, body: err_body}} ->
          {:error, {:http_error, status, err_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp handle_revision_response(resp, source_path, current_def, current_version, macro_name) do
    case parse_response(resp) do
      {:ok, :no_update} ->
        {:ok, :no_update}

      {:ok, {:update, new_definition}} ->
        # Merge the revised definition with version bump and changelog
        new_version = current_version + 1

        revised =
          new_definition
          |> Map.put("version", new_version)
          |> Map.put("_revision_history",
            (current_def["_revision_history"] || []) ++
              [%{
                "version" => new_version,
                "revised_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "from_version" => current_version,
                "macro_name" => macro_name
              }]
          )

        # Validate the revised definition parses correctly
        case Definition.parse(revised) do
          {:ok, _} ->
            atomic_write(source_path, revised)

          {:error, reason} ->
            Logger.warning("Macro.Revision: #{macro_name} revised definition is invalid: #{reason}")
            {:error, {:invalid_revision, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(%{"message" => %{"content" => content}}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, parsed} -> parse_revision_payload(parsed)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_response(resp) when is_binary(resp) do
    case Jason.decode(resp) do
      {:ok, parsed} -> parse_revision_payload(parsed)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # Direct map response (test mode)
  defp parse_response(%{"update" => _} = payload) do
    parse_revision_payload(payload)
  end

  defp parse_response(_), do: {:error, :unexpected_response}

  defp parse_revision_payload(%{"update" => true, "definition" => definition})
       when is_map(definition) do
    {:ok, {:update, definition}}
  end

  defp parse_revision_payload(%{"update" => false}) do
    {:ok, :no_update}
  end

  defp parse_revision_payload(_), do: {:error, :unexpected_format}

  defp atomic_write(path, definition) do
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with {:ok, json} <- Jason.encode(definition, pretty: true),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      {:ok, :updated}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  defp resolve_sidecar(nil), do: {"gemma4", Cranium.Config.ollama_url()}

  defp resolve_sidecar(profile_name) do
    case Cranium.Config.resolve_profile(profile_name) do
      {:ok, profile} ->
        {profile.model || "gemma4", Cranium.Config.ollama_url()}

      {:error, _} ->
        Logger.warning("Macro.Revision: profile '#{profile_name}' not found, using default")
        {"gemma4", Cranium.Config.ollama_url()}
    end
  end
end
