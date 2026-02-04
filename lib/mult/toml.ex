defmodule Mult.Toml do
  @moduledoc """
  A minimal TOML v1.0.0 parser sufficient for MULT/1 usage.

  Supports:
  - Key/value pairs (bare and quoted keys)
  - Tables ([table]) and array-of-tables ([[table]])
  - Strings (basic and literal, single-line)
  - Integers (decimal, hex, octal, binary)
  - Floats (decimal, inf, nan)
  - Booleans (true/false)
  - Datetimes (offset, local, local-date, local-time)
  - Arrays
  - Inline tables
  - Comments (#)
  """

  @doc "Parse a TOML string into a map. Returns {:ok, map} or {:error, reason}."
  def parse(input) when is_binary(input) do
    lines = String.split(input, ~r/\r?\n/)
    parse_lines(lines, %{}, [], nil)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def parse!(input) do
    case parse(input) do
      {:ok, result} -> result
      {:error, reason} -> raise "TOML parse error: #{reason}"
    end
  end

  # --- Line-by-line parser ---

  defp parse_lines([], root, _current_path, _array_path) do
    {:ok, root}
  end

  defp parse_lines([line | rest], root, current_path, array_path) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_lines(rest, root, current_path, array_path)

      String.starts_with?(trimmed, "[[") ->
        case parse_array_table_header(trimmed) do
          {:ok, path} ->
            root = ensure_array_table(root, path)
            parse_lines(rest, root, path, {:array, path})

          {:error, reason} ->
            {:error, reason}
        end

      String.starts_with?(trimmed, "[") ->
        case parse_table_header(trimmed) do
          {:ok, path} ->
            root = ensure_table(root, path)
            parse_lines(rest, root, path, nil)

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        case parse_key_value(trimmed) do
          {:ok, keys, value} ->
            effective_path =
              case array_path do
                {:array, apath} -> apath ++ [:last]
                _ -> current_path
              end

            full_path = effective_path ++ keys

            case put_nested(root, full_path, value) do
              {:ok, root} -> parse_lines(rest, root, current_path, array_path)
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- Table headers ---

  defp parse_table_header(line) do
    line = strip_comment(line)

    case Regex.run(~r/^\[(.+)\]\s*$/, line) do
      [_, key_str] ->
        parse_key_path(String.trim(key_str))

      _ ->
        {:error, "Invalid table header: #{line}"}
    end
  end

  defp parse_array_table_header(line) do
    line = strip_comment(line)

    case Regex.run(~r/^\[\[(.+)\]\]\s*$/, line) do
      [_, key_str] ->
        parse_key_path(String.trim(key_str))

      _ ->
        {:error, "Invalid array table header: #{line}"}
    end
  end

  # --- Key paths ---

  defp parse_key_path(str) do
    parse_dotted_key(str, [])
  end

  defp parse_dotted_key("", acc), do: {:ok, Enum.reverse(acc)}

  defp parse_dotted_key(str, acc) do
    case parse_single_key(str) do
      {:ok, key, rest} ->
        rest = String.trim_leading(rest)

        case rest do
          "" ->
            {:ok, Enum.reverse([key | acc])}

          "." <> rest2 ->
            parse_dotted_key(String.trim_leading(rest2), [key | acc])

          _ ->
            {:error, "Expected '.' or end of key path, got: #{rest}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_single_key("\"" <> rest) do
    case parse_basic_string_content(rest, "") do
      {:ok, value, rest} -> {:ok, value, rest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_single_key("'" <> rest) do
    case parse_literal_string_content(rest, "") do
      {:ok, value, rest} -> {:ok, value, rest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_single_key(str) do
    case Regex.run(~r/^([A-Za-z0-9_-]+)(.*)$/, str) do
      [_, key, rest] -> {:ok, key, rest}
      _ -> {:error, "Invalid key: #{str}"}
    end
  end

  # --- Key/value pairs ---

  defp parse_key_value(line) do
    case split_key_value(line) do
      {:ok, key_str, value_str} ->
        case parse_key_path(String.trim(key_str)) do
          {:ok, keys} ->
            case parse_value(String.trim(value_str)) do
              {:ok, value, _rest} -> {:ok, keys, value}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_key_value(line) do
    case find_equals(line, 0, false, false) do
      {:ok, pos} ->
        key = String.slice(line, 0, pos)
        value = String.slice(line, (pos + 1)..-1//1)
        {:ok, key, value}

      :not_found ->
        {:error, "No '=' found in key/value line: #{line}"}
    end
  end

  defp find_equals(str, pos, in_basic, in_literal) do
    case String.at(str, pos) do
      nil ->
        :not_found

      "\"" when not in_literal ->
        find_equals(str, pos + 1, not in_basic, in_literal)

      "'" when not in_basic ->
        find_equals(str, pos + 1, in_basic, not in_literal)

      "\\" when in_basic ->
        find_equals(str, pos + 2, in_basic, in_literal)

      "=" when not in_basic and not in_literal ->
        {:ok, pos}

      _ ->
        find_equals(str, pos + 1, in_basic, in_literal)
    end
  end

  # --- Value parser ---

  defp parse_value(str) do
    str = String.trim(str)

    cond do
      str == "" ->
        {:error, "Empty value"}

      String.starts_with?(str, "\"\"\"") ->
        parse_ml_basic_string(String.slice(str, 3..-1//1))

      String.starts_with?(str, "'''") ->
        parse_ml_literal_string(String.slice(str, 3..-1//1))

      String.starts_with?(str, "\"") ->
        case parse_basic_string_content(String.slice(str, 1..-1//1), "") do
          {:ok, value, rest} -> {:ok, value, rest}
          {:error, reason} -> {:error, reason}
        end

      String.starts_with?(str, "'") ->
        case parse_literal_string_content(String.slice(str, 1..-1//1), "") do
          {:ok, value, rest} -> {:ok, value, rest}
          {:error, reason} -> {:error, reason}
        end

      String.starts_with?(str, "[") ->
        parse_array(String.slice(str, 1..-1//1), [])

      String.starts_with?(str, "{") ->
        parse_inline_table(String.slice(str, 1..-1//1))

      str == "true" ->
        {:ok, true, ""}

      String.starts_with?(str, "true") ->
        {:ok, true, trim_rest(str, 4)}

      str == "false" ->
        {:ok, false, ""}

      String.starts_with?(str, "false") ->
        {:ok, false, trim_rest(str, 5)}

      str == "inf" or str == "+inf" ->
        {:ok, :infinity, ""}

      str == "-inf" ->
        {:ok, :neg_infinity, ""}

      str == "nan" or str == "+nan" or str == "-nan" ->
        {:ok, :nan, ""}

      true ->
        parse_number_or_datetime(str)
    end
  end

  defp trim_rest(str, skip) do
    String.slice(str, skip..-1//1)
  end

  # --- Strings ---

  defp parse_basic_string_content("", _acc), do: {:error, "Unterminated string"}

  defp parse_basic_string_content("\"" <> rest, acc) do
    {:ok, acc, rest}
  end

  defp parse_basic_string_content("\\" <> rest, acc) do
    case String.first(rest) do
      "n" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\n")
      "t" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\t")
      "r" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\r")
      "\\" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\\")
      "\"" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\"")
      "b" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\b")
      "f" -> parse_basic_string_content(String.slice(rest, 1..-1//1), acc <> "\f")
      "u" -> parse_unicode_escape(String.slice(rest, 1..-1//1), 4, acc)
      "U" -> parse_unicode_escape(String.slice(rest, 1..-1//1), 8, acc)
      _ -> {:error, "Invalid escape: \\#{String.first(rest)}"}
    end
  end

  defp parse_basic_string_content(str, acc) do
    {ch, rest} = String.split_at(str, 1)
    parse_basic_string_content(rest, acc <> ch)
  end

  defp parse_unicode_escape(str, n, acc) do
    hex = String.slice(str, 0, n)
    rest = String.slice(str, n..-1//1)

    case Integer.parse(hex, 16) do
      {codepoint, ""} ->
        parse_basic_string_content(rest, acc <> <<codepoint::utf8>>)

      _ ->
        {:error, "Invalid unicode escape: #{hex}"}
    end
  end

  defp parse_literal_string_content("", _acc), do: {:error, "Unterminated literal string"}

  defp parse_literal_string_content("'" <> rest, acc) do
    {:ok, acc, rest}
  end

  defp parse_literal_string_content(str, acc) do
    {ch, rest} = String.split_at(str, 1)
    parse_literal_string_content(rest, acc <> ch)
  end

  defp parse_ml_basic_string(str) do
    case String.split(str, "\"\"\"", parts: 2) do
      [content, rest] ->
        content =
          if String.starts_with?(content, "\n"), do: String.slice(content, 1..-1//1), else: content

        {:ok, content, rest}

      _ ->
        {:error, "Unterminated multi-line basic string"}
    end
  end

  defp parse_ml_literal_string(str) do
    case String.split(str, "'''", parts: 2) do
      [content, rest] ->
        content =
          if String.starts_with?(content, "\n"), do: String.slice(content, 1..-1//1), else: content

        {:ok, content, rest}

      _ ->
        {:error, "Unterminated multi-line literal string"}
    end
  end

  # --- Arrays ---

  defp parse_array(str, acc) do
    str = skip_whitespace_and_comments(str)

    cond do
      String.starts_with?(str, "]") ->
        {:ok, Enum.reverse(acc), String.slice(str, 1..-1//1)}

      true ->
        case parse_value(str) do
          {:ok, value, rest} ->
            rest = skip_whitespace_and_comments(rest)

            rest =
              if String.starts_with?(rest, ","),
                do: skip_whitespace_and_comments(String.slice(rest, 1..-1//1)),
                else: rest

            parse_array(rest, [value | acc])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- Inline tables ---

  defp parse_inline_table(str) do
    parse_inline_table_entries(String.trim(str), %{})
  end

  defp parse_inline_table_entries("}" <> rest, acc) do
    {:ok, acc, rest}
  end

  defp parse_inline_table_entries("" , _acc) do
    {:error, "Unterminated inline table"}
  end

  defp parse_inline_table_entries(str, acc) do
    case split_key_value_inline(str) do
      {:ok, key_str, value_str, after_value} ->
        case parse_key_path(String.trim(key_str)) do
          {:ok, keys} ->
            case parse_value(String.trim(value_str)) do
              {:ok, value, value_rest} ->
                combined = String.trim(value_rest <> after_value)

                case put_nested(acc, keys, value) do
                  {:ok, acc} ->
                    combined =
                      cond do
                        String.starts_with?(combined, ",") ->
                          String.trim(String.slice(combined, 1..-1//1))

                        String.starts_with?(combined, "}") ->
                          combined

                        true ->
                          combined
                      end

                    parse_inline_table_entries(combined, acc)

                  {:error, reason} ->
                    {:error, reason}
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_key_value_inline(str) do
    case find_equals(str, 0, false, false) do
      {:ok, pos} ->
        key = String.slice(str, 0, pos)
        rest = String.slice(str, (pos + 1)..-1//1)

        case find_value_end_inline(String.trim(rest)) do
          {:ok, value, after_value} ->
            {:ok, key, value, after_value}

          {:error, reason} ->
            {:error, reason}
        end

      :not_found ->
        {:error, "No '=' in inline table entry"}
    end
  end

  defp find_value_end_inline(str) do
    # For inline table, we parse the value and return rest
    {:ok, str, ""}
  end

  # --- Numbers and Datetimes ---

  defp parse_number_or_datetime(str) do
    # Extract the token (up to comma, ], }, whitespace, or comment)
    {token, rest} = extract_token(str)

    cond do
      # Datetime patterns
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/, token) ->
        {:ok, token, rest}

      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, token) ->
        {:ok, token, rest}

      Regex.match?(~r/^\d{2}:\d{2}:\d{2}/, token) ->
        {:ok, token, rest}

      # Hex
      String.starts_with?(token, "0x") or String.starts_with?(token, "0X") ->
        clean = String.replace(String.slice(token, 2..-1//1), "_", "")
        case Integer.parse(clean, 16) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, "Invalid hex: #{token}"}
        end

      # Octal
      String.starts_with?(token, "0o") or String.starts_with?(token, "0O") ->
        clean = String.replace(String.slice(token, 2..-1//1), "_", "")
        case Integer.parse(clean, 8) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, "Invalid octal: #{token}"}
        end

      # Binary
      String.starts_with?(token, "0b") or String.starts_with?(token, "0B") ->
        clean = String.replace(String.slice(token, 2..-1//1), "_", "")
        case Integer.parse(clean, 2) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, "Invalid binary: #{token}"}
        end

      # Float (contains . or e/E)
      String.contains?(token, ".") or String.contains?(token, "e") or String.contains?(token, "E") ->
        clean = String.replace(token, "_", "")
        case Float.parse(clean) do
          {f, ""} -> {:ok, f, rest}
          _ -> {:error, "Invalid float: #{token}"}
        end

      # Integer
      true ->
        clean = String.replace(token, "_", "")
        case Integer.parse(clean) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, "Invalid number: #{token}"}
        end
    end
  end

  defp extract_token(str) do
    case Regex.run(~r/^([^\s,\]\}#]+)(.*)$/s, str) do
      [_, token, rest] -> {token, rest}
      _ -> {str, ""}
    end
  end

  # --- Helpers ---

  defp skip_whitespace_and_comments(str) do
    str = String.trim_leading(str)

    if String.starts_with?(str, "#") do
      # Skip to end of line
      case String.split(str, "\n", parts: 2) do
        [_, rest] -> skip_whitespace_and_comments(rest)
        _ -> ""
      end
    else
      if String.starts_with?(str, "\n") or String.starts_with?(str, "\r") do
        skip_whitespace_and_comments(String.trim_leading(str, "\r\n"))
      else
        str
      end
    end
  end

  defp strip_comment(line) do
    # Strip trailing comments (not inside strings)
    strip_comment_helper(line, 0, false, false)
  end

  defp strip_comment_helper(line, pos, in_basic, in_literal) do
    case String.at(line, pos) do
      nil ->
        line

      "\"" when not in_literal ->
        strip_comment_helper(line, pos + 1, not in_basic, in_literal)

      "'" when not in_basic ->
        strip_comment_helper(line, pos + 1, in_basic, not in_literal)

      "\\" when in_basic ->
        strip_comment_helper(line, pos + 2, in_basic, in_literal)

      "#" when not in_basic and not in_literal ->
        String.trim(String.slice(line, 0, pos))

      _ ->
        strip_comment_helper(line, pos + 1, in_basic, in_literal)
    end
  end

  defp ensure_table(root, path) do
    case get_nested(root, path) do
      {:ok, %{}} -> root
      :missing -> put_nested!(root, path, %{})
      _ -> root
    end
  end

  defp ensure_array_table(root, path) do
    case get_nested(root, path) do
      {:ok, list} when is_list(list) ->
        put_nested!(root, path, list ++ [%{}])

      :missing ->
        put_nested!(root, path, [%{}])

      _ ->
        put_nested!(root, path, [%{}])
    end
  end

  defp get_nested(map, []) when is_map(map), do: {:ok, map}
  defp get_nested(list, []) when is_list(list), do: {:ok, list}

  defp get_nested(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_nested(value, rest)
      :error -> :missing
    end
  end

  defp get_nested(_, _), do: :missing

  defp put_nested(map, [key], value) when is_map(map) do
    {:ok, Map.put(map, key, value)}
  end

  defp put_nested(map, [:last], value) when is_map(map) do
    {:ok, Map.put(map, :last, value)}
  end

  defp put_nested(map, [key | rest], value) when is_map(map) do
    sub = Map.get(map, key, %{})

    case rest do
      [:last | deeper_rest] when is_list(sub) ->
        last_idx = length(sub) - 1

        if last_idx >= 0 do
          last_map = Enum.at(sub, last_idx)

          case put_nested(last_map, deeper_rest, value) do
            {:ok, updated} ->
              {:ok, Map.put(map, key, List.replace_at(sub, last_idx, updated))}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, "Array table #{key} has no entries"}
        end

      _ ->
        case put_nested(sub, rest, value) do
          {:ok, updated} -> {:ok, Map.put(map, key, updated)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp put_nested(_, path, _value) do
    {:error, "Cannot set key at path #{inspect(path)}: parent is not a map"}
  end

  defp put_nested!(map, path, value) do
    case put_nested(map, path, value) do
      {:ok, result} -> result
      {:error, _} -> map
    end
  end

  # --- Encoder ---

  @doc "Encode a map to a TOML string."
  def encode(map) when is_map(map) do
    {simple, tables, array_tables} = partition_values(map)

    parts = []

    parts =
      if map_size(simple) > 0 do
        parts ++ [encode_pairs(simple)]
      else
        parts
      end

    parts = parts ++ encode_tables(tables, [])
    parts = parts ++ encode_array_tables(array_tables, [])

    Enum.join(parts, "\n")
  end

  defp partition_values(map) do
    Enum.reduce(map, {%{}, %{}, %{}}, fn {k, v}, {simple, tables, array_tables} ->
      cond do
        is_list(v) and length(v) > 0 and is_map(hd(v)) ->
          {simple, tables, Map.put(array_tables, k, v)}

        is_map(v) ->
          {simple, Map.put(tables, k, v), array_tables}

        true ->
          {Map.put(simple, k, v), tables, array_tables}
      end
    end)
  end

  defp encode_pairs(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> "#{encode_key(k)} = #{encode_value(v)}" end)
    |> Enum.join("\n")
  end

  defp encode_tables(tables, prefix) do
    tables
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.flat_map(fn {k, v} ->
      path = prefix ++ [k]
      header = "[#{Enum.join(path, ".")}]"
      {simple, sub_tables, sub_array_tables} = partition_values(v)

      parts = ["\n" <> header]

      parts =
        if map_size(simple) > 0 do
          parts ++ [encode_pairs(simple)]
        else
          parts
        end

      parts ++ encode_tables(sub_tables, path) ++ encode_array_tables(sub_array_tables, path)
    end)
  end

  defp encode_array_tables(array_tables, prefix) do
    array_tables
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.flat_map(fn {k, items} ->
      path = prefix ++ [k]
      header = "[[#{Enum.join(path, ".")}]]"

      Enum.flat_map(items, fn item ->
        {simple, sub_tables, sub_array_tables} = partition_values(item)

        parts = ["\n" <> header]

        parts =
          if map_size(simple) > 0 do
            parts ++ [encode_pairs(simple)]
          else
            parts
          end

        parts ++ encode_tables(sub_tables, path) ++ encode_array_tables(sub_array_tables, path)
      end)
    end)
  end

  defp encode_key(key) when is_binary(key) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, key) do
      key
    else
      "\"#{String.replace(key, "\"", "\\\"")}\""
    end
  end

  defp encode_value(value) when is_binary(value) do
    "\"#{escape_string(value)}\""
  end

  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(:infinity), do: "inf"
  defp encode_value(:neg_infinity), do: "-inf"
  defp encode_value(:nan), do: "nan"

  defp encode_value(list) when is_list(list) do
    items = Enum.map(list, &encode_value/1)
    "[#{Enum.join(items, ", ")}]"
  end

  defp encode_value(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "#{encode_key(k)} = #{encode_value(v)}" end)

    "{#{Enum.join(pairs, ", ")}}"
  end

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
  end
end
