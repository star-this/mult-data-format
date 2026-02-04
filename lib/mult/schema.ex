defmodule Mult.Schema do
  @moduledoc """
  LS-1 schema language implementation for MULT/1.

  Validates decoded block values against LS-1 schemas.
  Schemas are TOML mappings with type declarations, constraints,
  and nested sub-schemas.
  """

  @primitive_types ~w(string int float bool date datetime uuid ulid semver semver_req)
  @composite_types ~w(object array map table any)
  @all_types @primitive_types ++ @composite_types

  @doc """
  Validate a value against an LS-1 schema (given as a map).
  Returns :ok or {:error, reasons} where reasons is a list of error strings.
  """
  def validate(value, schema) when is_map(schema) do
    case do_validate(value, schema, []) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # --- Type dispatch ---

  defp do_validate(value, schema, path) do
    type = Map.get(schema, "type")

    unless type do
      [format_error(path, "Schema missing 'type' key")]
    else
      unless type in @all_types do
        [format_error(path, "Unknown type '#{type}'")]
      else
        type_errors = validate_type(type, value, schema, path)
        constraint_errors = validate_constraints(value, schema, path)
        type_errors ++ constraint_errors
      end
    end
  end

  # --- Composite types ---

  defp validate_type("any", _value, _schema, _path), do: []

  defp validate_type("object", value, schema, path) when is_map(value) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    required_errors =
      Enum.flat_map(required, fn key ->
        if Map.has_key?(value, key) do
          []
        else
          [format_error(path, "Missing required key '#{key}'")]
        end
      end)

    prop_errors =
      Enum.flat_map(properties, fn {key, sub_schema} ->
        if Map.has_key?(value, key) do
          do_validate(Map.get(value, key), sub_schema, path ++ [key])
        else
          []
        end
      end)

    required_errors ++ prop_errors
  end

  defp validate_type("object", value, _schema, path) do
    [format_error(path, "Expected an object (map), got #{inspect_type(value)}")]
  end

  defp validate_type("array", value, schema, path) when is_list(value) do
    items_schema = Map.get(schema, "items")

    if items_schema do
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} ->
        do_validate(item, items_schema, path ++ ["[#{idx}]"])
      end)
    else
      []
    end
  end

  defp validate_type("array", value, _schema, path) do
    [format_error(path, "Expected an array, got #{inspect_type(value)}")]
  end

  defp validate_type("map", value, schema, path) when is_map(value) do
    keys_schema = Map.get(schema, "keys", %{"type" => "string"})
    values_schema = Map.get(schema, "values", %{"type" => "any"})

    Enum.flat_map(value, fn {k, v} ->
      key_errors = do_validate(k, keys_schema, path ++ ["<key:#{k}>"])
      value_errors = do_validate(v, values_schema, path ++ [k])
      key_errors ++ value_errors
    end)
  end

  defp validate_type("map", value, _schema, path) do
    [format_error(path, "Expected a map, got #{inspect_type(value)}")]
  end

  defp validate_type("table", value, schema, path) when is_list(value) do
    columns = Map.get(schema, "columns", [])

    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, idx} ->
      validate_table_row(row, columns, path ++ ["row[#{idx}]"])
    end)
  end

  defp validate_type("table", value, _schema, path) do
    [format_error(path, "Expected a table (list of rows), got #{inspect_type(value)}")]
  end

  # --- Primitive types ---

  defp validate_type("string", value, _schema, _path) when is_binary(value), do: []

  defp validate_type("string", value, _schema, path) do
    [format_error(path, "Expected string, got #{inspect_type(value)}")]
  end

  defp validate_type("int", value, _schema, _path) when is_integer(value), do: []

  defp validate_type("int", value, _schema, path) when is_binary(value) do
    case Integer.parse(value) do
      {_, ""} -> []
      _ -> [format_error(path, "Expected int, got string '#{value}'")]
    end
  end

  defp validate_type("int", value, _schema, path) do
    [format_error(path, "Expected int, got #{inspect_type(value)}")]
  end

  defp validate_type("float", value, _schema, _path)
       when is_float(value) or is_integer(value),
       do: []

  defp validate_type("float", value, _schema, path) when is_binary(value) do
    case Float.parse(value) do
      {_, ""} ->
        []

      _ ->
        case Integer.parse(value) do
          {_, ""} -> []
          _ -> [format_error(path, "Expected float, got string '#{value}'")]
        end
    end
  end

  defp validate_type("float", value, _schema, path) do
    [format_error(path, "Expected float, got #{inspect_type(value)}")]
  end

  defp validate_type("bool", value, _schema, _path) when is_boolean(value), do: []

  defp validate_type("bool", value, _schema, path) do
    [format_error(path, "Expected bool, got #{inspect_type(value)}")]
  end

  defp validate_type("date", value, _schema, path) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) do
      validate_date_value(value, path)
    else
      [format_error(path, "Expected date (YYYY-MM-DD), got '#{value}'")]
    end
  end

  defp validate_type("date", value, _schema, path) do
    [format_error(path, "Expected date string, got #{inspect_type(value)}")]
  end

  defp validate_type("datetime", value, _schema, path) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/, value) do
      []
    else
      [format_error(path, "Expected datetime (ISO-8601), got '#{value}'")]
    end
  end

  defp validate_type("datetime", value, _schema, path) do
    [format_error(path, "Expected datetime string, got #{inspect_type(value)}")]
  end

  defp validate_type("uuid", value, _schema, path) when is_binary(value) do
    if Regex.match?(
         ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
         value
       ) do
      []
    else
      [format_error(path, "Expected UUID, got '#{value}'")]
    end
  end

  defp validate_type("uuid", value, _schema, path) do
    [format_error(path, "Expected UUID string, got #{inspect_type(value)}")]
  end

  defp validate_type("ulid", value, _schema, path) when is_binary(value) do
    if Regex.match?(~r/^[0-9A-HJKMNP-TV-Z]{26}$/, value) do
      []
    else
      [format_error(path, "Expected ULID (26 Crockford Base32 chars), got '#{value}'")]
    end
  end

  defp validate_type("ulid", value, _schema, path) do
    [format_error(path, "Expected ULID string, got #{inspect_type(value)}")]
  end

  defp validate_type("semver", value, _schema, path) when is_binary(value) do
    if Regex.match?(~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$/, value) do
      []
    else
      [format_error(path, "Expected semver (MAJOR.MINOR.PATCH), got '#{value}'")]
    end
  end

  defp validate_type("semver", value, _schema, path) do
    [format_error(path, "Expected semver string, got #{inspect_type(value)}")]
  end

  defp validate_type("semver_req", value, _schema, path) when is_binary(value) do
    if String.trim(value) != "" do
      []
    else
      [format_error(path, "Expected non-empty semver_req, got empty string")]
    end
  end

  defp validate_type("semver_req", value, _schema, path) do
    [format_error(path, "Expected semver_req string, got #{inspect_type(value)}")]
  end

  # --- Table row validation ---

  defp validate_table_row(row, columns, path) when is_map(row) do
    Enum.flat_map(columns, fn col ->
      col_name = Map.get(col, "name")
      col_type = Map.get(col, "type", "string")
      optional = Map.get(col, "optional", false)

      case Map.fetch(row, col_name) do
        {:ok, value} ->
          if value == "" and optional do
            []
          else
            do_validate(value, %{"type" => col_type}, path ++ [col_name])
          end

        :error ->
          if optional do
            []
          else
            [format_error(path, "Missing required column '#{col_name}'")]
          end
      end
    end)
  end

  defp validate_table_row(_row, _columns, path) do
    [format_error(path, "Table row must be a map")]
  end

  # --- Constraints ---

  defp validate_constraints(value, schema, path) do
    errors = []

    errors =
      case Map.get(schema, "enum") do
        nil ->
          errors

        enum_values ->
          if value in enum_values do
            errors
          else
            errors ++
              [format_error(path, "Value #{inspect(value)} not in enum #{inspect(enum_values)}")]
          end
      end

    errors =
      case Map.get(schema, "pattern") do
        nil ->
          errors

        pattern when is_binary(value) ->
          case Regex.compile(pattern) do
            {:ok, re} ->
              if Regex.match?(re, value) do
                errors
              else
                errors ++
                  [format_error(path, "Value '#{value}' does not match pattern '#{pattern}'")]
              end

            {:error, _} ->
              errors ++ [format_error(path, "Invalid regex pattern: #{pattern}")]
          end

        _pattern ->
          errors
      end

    errors =
      if is_binary(value) do
        errors
        |> check_min_len(value, schema, path)
        |> check_max_len(value, schema, path)
      else
        errors
      end

    errors =
      if is_number(value) do
        errors
        |> check_min(value, schema, path)
        |> check_max(value, schema, path)
      else
        errors
      end

    errors
  end

  defp check_min_len(errors, value, schema, path) do
    case Map.get(schema, "min_len") do
      nil ->
        errors

      min_len ->
        if String.length(value) >= min_len,
          do: errors,
          else:
            errors ++
              [
                format_error(
                  path,
                  "String length #{String.length(value)} < min_len #{min_len}"
                )
              ]
    end
  end

  defp check_max_len(errors, value, schema, path) do
    case Map.get(schema, "max_len") do
      nil ->
        errors

      max_len ->
        if String.length(value) <= max_len,
          do: errors,
          else:
            errors ++
              [
                format_error(
                  path,
                  "String length #{String.length(value)} > max_len #{max_len}"
                )
              ]
    end
  end

  defp check_min(errors, value, schema, path) do
    case Map.get(schema, "min") do
      nil ->
        errors

      min ->
        if value >= min,
          do: errors,
          else: errors ++ [format_error(path, "Value #{value} < min #{min}")]
    end
  end

  defp check_max(errors, value, schema, path) do
    case Map.get(schema, "max") do
      nil ->
        errors

      max ->
        if value <= max,
          do: errors,
          else: errors ++ [format_error(path, "Value #{value} > max #{max}")]
    end
  end

  # --- Date validation ---

  defp validate_date_value(date_str, path) do
    case Date.from_iso8601(date_str) do
      {:ok, _} -> []
      {:error, _} -> [format_error(path, "Invalid date: #{date_str}")]
    end
  end

  # --- Helpers ---

  defp format_error([], msg), do: msg
  defp format_error(path, msg), do: "#{Enum.join(path, ".")}: #{msg}"

  defp inspect_type(v) when is_binary(v), do: "string"
  defp inspect_type(v) when is_integer(v), do: "integer"
  defp inspect_type(v) when is_float(v), do: "float"
  defp inspect_type(v) when is_boolean(v), do: "boolean"
  defp inspect_type(v) when is_list(v), do: "array"
  defp inspect_type(v) when is_map(v), do: "object"
  defp inspect_type(nil), do: "null"
  defp inspect_type(_v), do: "unknown"
end
