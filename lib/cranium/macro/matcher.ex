defmodule Cranium.Macro.Matcher do
  @moduledoc """
  Pattern matching for macro triggers and discoverable keywords.

  Compiles pattern strings into regexes at load time. Patterns come in two forms:

  - **Literal strings**: word-boundary wrapped, case-insensitive, hyphens and
    spaces interchangeable. `"kubernetes"` matches "Kubernetes", "KUBERNETES".
  - **Regex strings**: delimited by `/slashes/`, compiled raw.
    `"/kube[-\\s]?cluster/"` is passed through as-is.
  """

  @doc """
  Compile a pattern string into a Regex.

  Literal strings get word-boundary wrapping, case-insensitivity, and
  hyphen-space interchangeability. `/regex/` strings are compiled raw.

  Returns `{:ok, regex}` or `{:error, reason}`.
  """
  @spec compile_pattern(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def compile_pattern(pattern) when is_binary(pattern) do
    if regex_delimited?(pattern) do
      regex_str = String.slice(pattern, 1..-2//1)

      case Regex.compile(regex_str) do
        {:ok, regex} -> {:ok, regex}
        {:error, {reason, _}} -> {:error, "invalid regex: #{reason}"}
      end
    else
      compile_literal(pattern)
    end
  end

  @doc """
  Compile a list of pattern strings. Returns `{:ok, [regex]}` or
  `{:error, reason}` on first failure.
  """
  @spec compile_patterns([String.t()]) :: {:ok, [Regex.t()]} | {:error, String.t()}
  def compile_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.reduce_while({:ok, []}, fn pattern, {:ok, acc} ->
      case compile_pattern(pattern) do
        {:ok, regex} -> {:cont, {:ok, [regex | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  @doc """
  Check if any compiled pattern matches the given text.
  """
  @spec match?(text :: String.t(), compiled :: [Regex.t()]) :: boolean()
  def match?(text, compiled) when is_binary(text) and is_list(compiled) do
    Enum.any?(compiled, &Regex.match?(&1, text))
  end

  # --- Private ---

  defp regex_delimited?(pattern) do
    byte_size(pattern) > 2 and
      String.starts_with?(pattern, "/") and
      String.ends_with?(pattern, "/")
  end

  defp compile_literal(literal) do
    # Split on runs of hyphens/spaces, escape each segment, rejoin with
    # an interchangeable class that matches one or more of either.
    parts =
      literal
      |> String.split(~r/[\s-]+/, trim: true)
      |> Enum.map(&Regex.escape/1)

    pattern = Enum.join(parts, "[\\s\\-]+")

    # Only apply \b at edges bordering word characters — \b between two
    # non-word chars (like "?" at end of string) never matches.
    prefix = if Regex.match?(~r/^\w/, literal), do: "\\b", else: ""
    suffix = if Regex.match?(~r/\w$/, literal), do: "\\b", else: ""

    case Regex.compile("#{prefix}#{pattern}#{suffix}", "i") do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "failed to compile literal pattern: #{reason}"}
    end
  end
end
