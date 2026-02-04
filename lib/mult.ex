defmodule Mult do
  @moduledoc """
  MULT/1 — Woven Plain-Text Container Format codec.

  Provides parsing, encoding, and validation of MULT/1 documents.
  MULT/1 weaves multiple typed blocks (documentation, manifests, tables,
  schemas) into a single plain-text file.

  ## Usage

      # Parse a document
      {:ok, doc} = Mult.parse(File.read!("sample.mult"))

      # Access blocks
      doc.meta         # => decoded meta map
      doc.blocks       # => list of raw Block structs
      doc.schemas      # => %{"name" => schema_map}
      doc.decoded      # => list of {block, decoded_value}

      # Validate all schema-bound blocks
      Mult.validate(doc)

      # Encode back to string
      Mult.encode(doc)

      # Parse a file directly
      {:ok, doc} = Mult.parse_file("sample.mult")
  """

  alias Mult.Container
  alias Mult.Container.Block

  defstruct [
    :meta,
    :raw,
    blocks: [],
    schemas: %{},
    decoded: [],
    errors: []
  ]

  @type t :: %__MODULE__{
          meta: map() | nil,
          raw: String.t() | nil,
          blocks: [Block.t()],
          schemas: map(),
          decoded: [{Block.t(), any()}],
          errors: [String.t()]
        }

  @doc "Parse a MULT/1 document string. Returns {:ok, Mult.t()} or {:error, reason}."
  def parse(input) when is_binary(input) do
    with {:ok, blocks} <- Container.parse(input),
         :ok <- validate_meta_first(blocks),
         {:ok, doc} <- build_document(blocks, input) do
      {:ok, doc}
    end
  end

  @doc "Parse a MULT/1 document string, raising on error."
  def parse!(input) do
    case parse(input) do
      {:ok, doc} -> doc
      {:error, reason} -> raise "MULT parse error: #{reason}"
    end
  end

  @doc "Parse a MULT/1 file. Returns {:ok, Mult.t()} or {:error, reason}."
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, "Cannot read file #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Validate all schema-bound blocks in a document. Returns :ok or {:error, errors}."
  def validate(%__MODULE__{} = doc) do
    errors =
      doc.decoded
      |> Enum.flat_map(fn {block, decoded} ->
        schema_name = Map.get(block.attrs, "schema")

        if schema_name do
          case Map.fetch(doc.schemas, schema_name) do
            {:ok, schema} ->
              case Mult.Schema.validate(decoded, schema) do
                :ok ->
                  []

                {:error, errs} ->
                  Enum.map(errs, fn e ->
                    "Block '#{block.name || block.kind}' (schema=#{schema_name}): #{e}"
                  end)
              end

            :error ->
              ["Block '#{block.name || block.kind}': schema '#{schema_name}' not found"]
          end
        else
          []
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  @doc "Encode a MULT document back to a string."
  def encode(%__MODULE__{blocks: blocks}) do
    Container.encode(blocks)
  end

  @doc "Decode a single block's body based on its kind and attributes."
  def decode_block(%Block{kind: kind, body: body, attrs: attrs}) do
    lang = Map.get(attrs, "lang")

    case kind do
      "meta" -> decode_structured(body, lang || "toml")
      "toml" -> decode_structured(body, "toml")
      "syaml" -> decode_structured(body, "syaml")
      "tsv" -> Mult.Tsv.parse(body)
      "schema" -> decode_structured(body, lang || "toml")
      "md" -> {:ok, body}
      _ -> {:ok, body}
    end
  end

  @doc "Get all blocks of a given kind from a document."
  def get_blocks(%__MODULE__{blocks: blocks}, kind) do
    Enum.filter(blocks, &(&1.kind == kind))
  end

  @doc "Get a block by name from a document."
  def get_block_by_name(%__MODULE__{blocks: blocks}, name) do
    Enum.find(blocks, &(&1.name == name))
  end

  @doc "Get the decoded value for a named block."
  def get_decoded(%__MODULE__{decoded: decoded}, name) do
    case Enum.find(decoded, fn {block, _} -> block.name == name end) do
      {_block, value} -> {:ok, value}
      nil -> :error
    end
  end

  # --- Internal ---

  defp validate_meta_first([]) do
    {:error, "Empty document: no blocks found"}
  end

  defp validate_meta_first([%Block{kind: "meta"} | _]) do
    :ok
  end

  defp validate_meta_first([%Block{kind: other} | _]) do
    {:error, "First block must be 'meta', got '#{other}'"}
  end

  defp build_document(blocks, raw) do
    doc = %__MODULE__{blocks: blocks, raw: raw}

    {decoded, errors} =
      blocks
      |> Enum.reduce({[], []}, fn block, {dec_acc, err_acc} ->
        case decode_block(block) do
          {:ok, value} ->
            {[{block, value} | dec_acc], err_acc}

          {:error, reason} ->
            error_msg =
              "Failed to decode #{block.kind} block '#{block.name}' at line #{block.line}: #{reason}"

            {[{block, nil} | dec_acc], [error_msg | err_acc]}
        end
      end)

    decoded = Enum.reverse(decoded)
    errors = Enum.reverse(errors)

    meta =
      case Enum.find(decoded, fn {block, _} -> block.kind == "meta" end) do
        {_, value} -> value
        nil -> nil
      end

    schemas =
      decoded
      |> Enum.filter(fn {block, _} -> block.kind == "schema" end)
      |> Enum.reduce(%{}, fn {block, value}, acc ->
        schema_name = Map.get(block.attrs, "name") || block.name
        if schema_name, do: Map.put(acc, schema_name, value), else: acc
      end)

    doc = %{doc | meta: meta, schemas: schemas, decoded: decoded, errors: errors}
    {:ok, doc}
  end

  defp decode_structured(body, "toml") do
    Mult.Toml.parse(body)
  end

  defp decode_structured(body, "syaml") do
    Mult.Syaml.parse(body)
  end

  defp decode_structured(_body, lang) do
    {:error, "Unsupported inner language: #{lang}"}
  end
end
