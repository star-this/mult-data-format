defmodule Mult.Tsv do
  @moduledoc """
  TSV-1 parser and encoder for MULT/1.

  Parses tab-separated values with:
  - First row as header
  - Escape sequences: \\t, \\n, \\\\
  - Decodes to list of row maps
  """

  @doc "Parse a TSV-1 string into a list of row maps. Returns {:ok, rows} or {:error, reason}."
  def parse(input) when is_binary(input) do
    lines =
      input
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] ->
        {:ok, []}

      [header_line | data_lines] ->
        headers = split_row(header_line)
        rows = Enum.map(data_lines, &parse_row(&1, headers))
        {:ok, rows}
    end
  end

  def parse!(input) do
    case parse(input) do
      {:ok, result} -> result
      {:error, reason} -> raise "TSV-1 parse error: #{reason}"
    end
  end

  defp split_row(line) do
    line
    |> String.split("\t")
    |> Enum.map(&unescape/1)
  end

  defp parse_row(line, headers) do
    cells = split_row(line)

    headers
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {header, idx}, acc ->
      value = Enum.at(cells, idx, "")
      Map.put(acc, header, value)
    end)
  end

  defp unescape(str) do
    str
    |> String.replace("\\\\", "\x00BACKSLASH\x00")
    |> String.replace("\\t", "\t")
    |> String.replace("\\n", "\n")
    |> String.replace("\x00BACKSLASH\x00", "\\")
  end

  # --- Encoder ---

  @doc "Encode a list of row maps to TSV-1 string. Requires a list of column names for ordering."
  def encode(rows, columns) when is_list(rows) and is_list(columns) do
    header = Enum.join(columns, "\t")

    data_lines =
      Enum.map(rows, fn row ->
        columns
        |> Enum.map(fn col ->
          value = Map.get(row, col, "")
          escape(to_string(value))
        end)
        |> Enum.join("\t")
      end)

    Enum.join([header | data_lines], "\n")
  end

  defp escape(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\t", "\\t")
    |> String.replace("\n", "\\n")
  end
end
