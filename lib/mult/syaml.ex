defmodule Mult.Syaml do
  @moduledoc """
  SYAML-1: A safe YAML subset parser for MULT/1.

  Supports only:
  - Block-style mappings (key: value)
  - Block-style sequences (- item)
  - Scalars: plain strings, double-quoted strings, int, float, bool, null
  - Comments beginning with #

  Rejects:
  - Tags and type directives (!)
  - Anchors and aliases (& and *)
  - Merge keys (<<)
  - Flow style collections ({...} and [...])
  - Multi-document streams (--- / ...)
  - Multiline scalars (| or >)
  - Any behavior that constructs arbitrary objects
  """

  @doc "Parse a SYAML-1 string. Returns {:ok, value} or {:error, reason}."
  def parse(input) when is_binary(input) do
    lines =
      input
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> reject_forbidden()

    case lines do
      {:error, reason} -> {:error, reason}
      lines ->
        tokens = tokenize(lines)
        case parse_value(tokens, 0) do
          {:ok, value, _rest} -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def parse!(input) do
    case parse(input) do
      {:ok, result} -> result
      {:error, reason} -> raise "SYAML-1 parse error: #{reason}"
    end
  end

  # --- Forbidden construct detection ---

  defp reject_forbidden(lines) do
    Enum.reduce_while(lines, [], fn {line, lineno}, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          {:cont, acc}

        String.starts_with?(trimmed, "---") ->
          {:halt, {:error, "SYAML-1 forbids multi-document streams (---) at line #{lineno}"}}

        String.starts_with?(trimmed, "...") ->
          {:halt, {:error, "SYAML-1 forbids multi-document streams (...) at line #{lineno}"}}

        Regex.match?(~r/![\w]/, trimmed) ->
          {:halt, {:error, "SYAML-1 forbids tags (!) at line #{lineno}"}}

        String.contains?(trimmed, "&") and Regex.match?(~r/&\w/, trimmed) ->
          {:halt, {:error, "SYAML-1 forbids anchors (&) at line #{lineno}"}}

        String.contains?(trimmed, "*") and Regex.match?(~r/\*\w/, trimmed) ->
          {:halt, {:error, "SYAML-1 forbids aliases (*) at line #{lineno}"}}

        Regex.match?(~r/^<<\s*:/, trimmed) ->
          {:halt, {:error, "SYAML-1 forbids merge keys (<<) at line #{lineno}"}}

        Regex.match?(~r/[|>]\s*$/, trimmed) and Regex.match?(~r/:\s+[|>]\s*$/, trimmed) ->
          {:halt, {:error, "SYAML-1 forbids multiline scalars (| or >) at line #{lineno}"}}

        # Flow collections at the value position are forbidden
        Regex.match?(~r/:\s+[\{\[]/, trimmed) ->
          {:halt, {:error, "SYAML-1 forbids flow style collections at line #{lineno}"}}

        # Top-level flow collections
        String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
          {:halt, {:error, "SYAML-1 forbids flow style collections at line #{lineno}"}}

        true ->
          {:cont, acc ++ [{line, lineno}]}
      end
    end)
  end

  # --- Tokenizer ---

  defp tokenize(lines) do
    Enum.map(lines, fn {line, lineno} ->
      indent = indent_level(line)
      content = String.trim(line)
      {indent, content, lineno}
    end)
    |> Enum.reject(fn {_, content, _} -> content == "" end)
  end

  defp indent_level(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " "))
    |> length()
  end

  # --- Parser ---

  defp parse_value([], _min_indent) do
    {:ok, nil, []}
  end

  defp parse_value([{indent, content, _lineno} | _rest] = tokens, min_indent) do
    if indent < min_indent do
      {:ok, nil, tokens}
    else
      cond do
        String.starts_with?(content, "- ") or content == "-" ->
          parse_sequence(tokens, indent)

        String.contains?(content, ":") and is_mapping_line?(content) ->
          parse_mapping(tokens, indent)

        true ->
          # Bare scalar
          [{_indent, content, _lineno} | rest] = tokens
          {:ok, parse_scalar(content), rest}
      end
    end
  end

  defp is_mapping_line?(content) do
    # A mapping line has "key:" or "key: value"
    # But not if the colon is inside a quoted string at the start
    cond do
      String.starts_with?(content, "\"") ->
        # Check if there's a : after the closing quote
        case Regex.run(~r/^"(?:[^"\\]|\\.)*"\s*:/, content) do
          nil -> false
          _ -> true
        end

      String.starts_with?(content, "- ") ->
        false

      true ->
        Regex.match?(~r/^[^#]*\S\s*:(\s|$)/, content)
    end
  end

  # --- Sequences ---

  defp parse_sequence(tokens, base_indent) do
    parse_sequence_items(tokens, base_indent, [])
  end

  defp parse_sequence_items([], _base_indent, acc) do
    {:ok, Enum.reverse(acc), []}
  end

  defp parse_sequence_items([{indent, _content, _lineno} | _rest] = tokens, base_indent, acc)
       when indent < base_indent do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_sequence_items([{indent, content, _lineno} | rest] = tokens, base_indent, acc)
       when indent == base_indent do
    if String.starts_with?(content, "- ") or content == "-" do
      item_str =
        if content == "-", do: "", else: String.trim(String.slice(content, 2..-1//1))

      if item_str == "" do
        # Multi-line value under this sequence item
        case parse_value(rest, indent + 1) do
          {:ok, value, rest2} ->
            parse_sequence_items(rest2, base_indent, [value | acc])

          {:error, reason} ->
            {:error, reason}
        end
      else
        if is_mapping_line?(item_str) do
          # Inline mapping start: "- key: value"
          synthetic = [{indent + 2, item_str, 0}]

          # Gather continuation lines that are deeper
          {deeper_lines, remaining} = gather_deeper(rest, indent + 2)
          all_lines = synthetic ++ deeper_lines

          case parse_mapping(all_lines, indent + 2) do
            {:ok, map, _leftover} ->
              parse_sequence_items(remaining, base_indent, [map | acc])

            {:error, reason} ->
              {:error, reason}
          end
        else
          value = parse_scalar(item_str)
          parse_sequence_items(rest, base_indent, [value | acc])
        end
      end
    else
      {:ok, Enum.reverse(acc), tokens}
    end
  end

  defp parse_sequence_items(tokens, _base_indent, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp gather_deeper(tokens, min_indent) do
    {deeper, rest} =
      Enum.split_while(tokens, fn {indent, _content, _lineno} ->
        indent >= min_indent
      end)

    {deeper, rest}
  end

  # --- Mappings ---

  defp parse_mapping(tokens, base_indent) do
    parse_mapping_pairs(tokens, base_indent, %{})
  end

  defp parse_mapping_pairs([], _base_indent, acc) do
    {:ok, acc, []}
  end

  defp parse_mapping_pairs([{indent, _content, _lineno} | _rest] = tokens, base_indent, acc)
       when indent < base_indent do
    {:ok, acc, tokens}
  end

  defp parse_mapping_pairs([{indent, content, _lineno} | rest], base_indent, acc)
       when indent == base_indent do
    case split_mapping_entry(content) do
      {:ok, key, value_str} ->
        value_str = String.trim(value_str)

        if value_str == "" do
          # Value on next lines
          case parse_value(rest, indent + 1) do
            {:ok, value, rest2} ->
              parse_mapping_pairs(rest2, base_indent, Map.put(acc, key, value))

            {:error, reason} ->
              {:error, reason}
          end
        else
          value = parse_scalar(value_str)
          parse_mapping_pairs(rest, base_indent, Map.put(acc, key, value))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_mapping_pairs(tokens, _base_indent, acc) do
    {:ok, acc, tokens}
  end

  defp split_mapping_entry(content) do
    case Regex.run(~r/^([^:]+):\s*(.*)$/, content) do
      [_, key, value] ->
        key = String.trim(key)
        # Strip comment from value if present
        value = strip_inline_comment(value)
        {:ok, key, value}

      _ ->
        {:error, "Invalid mapping entry: #{content}"}
    end
  end

  defp strip_inline_comment(str) do
    # Simple comment stripping - only outside quotes
    case Regex.run(~r/^("(?:[^"\\]|\\.)*")\s*#.*$/, str) do
      [_, quoted] -> quoted
      _ ->
        case Regex.run(~r/^([^#]*?)\s+#.*$/, str) do
          [_, value] -> String.trim(value)
          _ -> String.trim(str)
        end
    end
  end

  # --- Scalar parsing ---

  defp parse_scalar(str) do
    str = String.trim(str)
    # Strip trailing comment
    str = strip_inline_comment(str)

    cond do
      str == "null" or str == "~" -> nil
      str == "true" -> true
      str == "false" -> false

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        inner = String.slice(str, 1..-2//1)
        unescape_string(inner)

      Regex.match?(~r/^-?\d+$/, str) ->
        String.to_integer(str)

      Regex.match?(~r/^-?\d+\.\d+([eE][+-]?\d+)?$/, str) ->
        {f, ""} = Float.parse(str)
        f

      true ->
        str
    end
  end

  defp unescape_string(str) do
    str
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
  end

  # --- Encoder ---

  @doc "Encode a value to SYAML-1 string."
  def encode(value), do: encode_value(value, 0)

  defp encode_value(nil, _indent), do: "null"
  defp encode_value(true, _indent), do: "true"
  defp encode_value(false, _indent), do: "false"

  defp encode_value(s, _indent) when is_binary(s) do
    if needs_quoting?(s) do
      "\"#{escape_string(s)}\""
    else
      s
    end
  end

  defp encode_value(n, _indent) when is_integer(n), do: Integer.to_string(n)
  defp encode_value(f, _indent) when is_float(f), do: Float.to_string(f)

  defp encode_value(list, indent) when is_list(list) do
    items =
      Enum.map(list, fn item ->
        prefix = String.duplicate(" ", indent)
        encoded = encode_value(item, indent + 2)

        if is_map(item) or is_list(item) do
          "#{prefix}- #{String.trim_leading(encoded)}"
        else
          "#{prefix}- #{encoded}"
        end
      end)

    Enum.join(items, "\n")
  end

  defp encode_value(map, indent) when is_map(map) do
    prefix = String.duplicate(" ", indent)

    pairs =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} ->
        if is_map(v) or is_list(v) do
          child = encode_value(v, indent + 2)
          "#{prefix}#{k}:\n#{child}"
        else
          "#{prefix}#{k}: #{encode_value(v, 0)}"
        end
      end)

    Enum.join(pairs, "\n")
  end

  defp needs_quoting?(s) do
    s == "" or
      s == "null" or s == "~" or
      s == "true" or s == "false" or
      String.contains?(s, ":") or
      String.contains?(s, "#") or
      String.contains?(s, "\n") or
      String.contains?(s, "\"") or
      Regex.match?(~r/^\d/, s)
  end

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end
end
