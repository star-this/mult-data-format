defmodule Mult.Container do
  @moduledoc """
  MULT/1 container parser and encoder.

  Handles block framing: `<<<` start markers, `>>>` end markers,
  header parsing (kind, name, attributes), and body extraction.
  """

  defmodule Block do
    @moduledoc "A parsed MULT/1 block."
    defstruct [
      :kind,
      :name,
      :body,
      attrs: %{},
      line: nil
    ]

    @type t :: %__MODULE__{
            kind: String.t(),
            name: String.t() | nil,
            body: String.t(),
            attrs: map(),
            line: non_neg_integer()
          }
  end

  @doc """
  Parse a MULT/1 document string into a list of blocks.
  Returns {:ok, [Block.t()]} or {:error, reason}.
  """
  def parse(input) when is_binary(input) do
    lines = String.split(input, ~r/\r?\n/)
    parse_lines(lines, 1, nil, [], [])
  end

  # Not inside a block
  defp parse_lines([], _lineno, nil, _body_acc, blocks) do
    {:ok, Enum.reverse(blocks)}
  end

  # Inside a block but hit EOF -> unterminated
  defp parse_lines([], _lineno, current, _body_acc, _blocks) do
    {:error, "Unterminated block '#{current.kind}' starting at line #{current.line}"}
  end

  # Not inside a block
  defp parse_lines([line | rest], lineno, nil, _body_acc, blocks) do
    trimmed = String.trim_trailing(line)

    cond do
      # Container comment
      String.starts_with?(line, ";;") ->
        parse_lines(rest, lineno + 1, nil, [], blocks)

      # Blank line
      trimmed == "" ->
        parse_lines(rest, lineno + 1, nil, [], blocks)

      # Block start
      String.starts_with?(line, "<<<") ->
        case parse_header(line) do
          {:ok, block} ->
            block = %{block | line: lineno}
            parse_lines(rest, lineno + 1, block, [], blocks)

          {:error, reason} ->
            {:error, "Line #{lineno}: #{reason}"}
        end

      # Lines outside blocks that aren't comments or blank are ignored
      # (per spec, only blank lines and comment lines outside blocks)
      true ->
        parse_lines(rest, lineno + 1, nil, [], blocks)
    end
  end

  # Inside a block
  defp parse_lines([line | rest], lineno, current, body_acc, blocks) do
    if end_marker?(line) do
      body = body_acc |> Enum.reverse() |> Enum.join("\n")
      # Strip leading and trailing newline from body
      body = String.trim(body, "\n")
      block = %{current | body: body}
      parse_lines(rest, lineno + 1, nil, [], [block | blocks])
    else
      parse_lines(rest, lineno + 1, current, [line | body_acc], blocks)
    end
  end

  @doc "Check if a line is an end marker (>>> at column 1)."
  def end_marker?(line) do
    # Must start at column 1 with >>>
    trimmed = String.trim_trailing(line)
    trimmed == ">>>" or String.starts_with?(line, ">>>") and String.trim(line) == ">>>"
  end

  @doc "Parse a block header line into a Block struct (without body)."
  def parse_header(line) do
    # Remove <<< prefix
    rest = String.slice(line, 3..-1//1)
    rest = String.trim_leading(rest)

    if rest == "" do
      {:error, "Block header missing KIND"}
    else
      case parse_kind(rest) do
        {:ok, kind, rest} ->
          rest = String.trim_leading(rest)

          case parse_name_and_attrs(rest) do
            {:ok, name, attrs} ->
              {:ok, %Block{kind: kind, name: name, attrs: attrs}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_kind(str) do
    case Regex.run(~r/^([a-z][a-z0-9_-]*)(.*)$/, str) do
      [_, kind, rest] -> {:ok, kind, rest}
      _ -> {:error, "Invalid KIND in header: #{str}"}
    end
  end

  defp parse_name_and_attrs("") do
    {:ok, nil, %{}}
  end

  defp parse_name_and_attrs(str) do
    tokens = tokenize_header(str)
    extract_name_and_attrs(tokens)
  end

  defp tokenize_header(str) do
    tokenize_header(String.trim(str), [])
  end

  defp tokenize_header("", acc), do: Enum.reverse(acc)

  defp tokenize_header(str, acc) do
    str = String.trim_leading(str)

    if str == "" do
      Enum.reverse(acc)
    else
      case parse_header_token(str) do
        {:ok, token, rest} ->
          tokenize_header(rest, [token | acc])

        {:error, _reason} ->
          # Skip problematic character
          Enum.reverse(acc)
      end
    end
  end

  defp parse_header_token(str) do
    # Check for key=value
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_-]*)=(.*)$/, str) do
      [_, key, rest] ->
        case parse_attr_value(rest) do
          {:ok, value, rest2} ->
            {:ok, {:attr, key, value}, rest2}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        # It's a name token (no = sign, no spaces)
        case Regex.run(~r/^(\S+)(.*)$/, str) do
          [_, token, rest] -> {:ok, {:name, token}, rest}
          _ -> {:error, "Cannot parse header token from: #{str}"}
        end
    end
  end

  defp parse_attr_value("\"" <> rest) do
    parse_quoted_value(rest, "")
  end

  defp parse_attr_value(str) do
    case Regex.run(~r/^(\S+)(.*)$/, str) do
      [_, value, rest] -> {:ok, value, rest}
      _ -> {:ok, "", str}
    end
  end

  defp parse_quoted_value("", _acc), do: {:error, "Unterminated quoted attribute value"}

  defp parse_quoted_value("\\\"" <> rest, acc) do
    parse_quoted_value(rest, acc <> "\"")
  end

  defp parse_quoted_value("\\\\" <> rest, acc) do
    parse_quoted_value(rest, acc <> "\\")
  end

  defp parse_quoted_value("\"" <> rest, acc) do
    {:ok, acc, rest}
  end

  defp parse_quoted_value(<<ch::utf8, rest::binary>>, acc) do
    parse_quoted_value(rest, acc <> <<ch::utf8>>)
  end

  defp extract_name_and_attrs(tokens) do
    # First non-attr token is the positional name, rest must be attrs
    {name, attrs} =
      Enum.reduce(tokens, {nil, %{}}, fn
        {:name, n}, {nil, attrs} -> {n, attrs}
        {:name, n}, {_name, attrs} -> {n, attrs}
        {:attr, k, v}, {name, attrs} -> {name, Map.put(attrs, k, v)}
      end)

    # If no positional name, use the "name" attribute
    name = name || Map.get(attrs, "name")

    {:ok, name, attrs}
  end

  # --- Encoder ---

  @doc "Encode a list of blocks back to a MULT/1 document string."
  def encode(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&encode_block/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp encode_block(%Block{} = block) do
    header = encode_header(block)
    "#{header}\n#{block.body}\n>>>"
  end

  defp encode_header(%Block{kind: kind, name: name, attrs: attrs}) do
    parts = ["<<<", kind]

    parts =
      if name do
        parts ++ [name]
      else
        parts
      end

    # Sort attributes for canonicalization
    attr_parts =
      attrs
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} ->
        if String.contains?(v, " ") or String.contains?(v, "\"") do
          escaped = v |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
          "#{k}=\"#{escaped}\""
        else
          "#{k}=#{v}"
        end
      end)

    Enum.join(parts ++ attr_parts, " ")
  end
end
