defmodule MultTest do
  use ExUnit.Case

  # ── Container parsing ──────────────────────────────────────────

  describe "Container.parse/1" do
    test "parses a minimal document with one meta block" do
      input = """
      <<< meta lang=toml
      id = "test"
      >>>
      """

      {:ok, blocks} = Mult.Container.parse(input)
      assert length(blocks) == 1
      [block] = blocks
      assert block.kind == "meta"
      assert block.attrs == %{"lang" => "toml"}
    end

    test "parses multiple blocks" do
      input = """
      <<< meta lang=toml
      id = "test"
      >>>

      <<< md name=readme
      # Hello
      >>>

      <<< toml name=data schema="myschema"
      key = "value"
      >>>
      """

      {:ok, blocks} = Mult.Container.parse(input)
      assert length(blocks) == 3
      assert Enum.map(blocks, & &1.kind) == ["meta", "md", "toml"]
      assert Enum.at(blocks, 2).attrs["schema"] == "myschema"
    end

    test "rejects unterminated blocks" do
      input = """
      <<< meta lang=toml
      id = "test"
      """

      {:error, msg} = Mult.Container.parse(input)
      assert msg =~ "Unterminated"
    end

    test "preserves unknown block kinds" do
      input = """
      <<< meta lang=toml
      id = "x"
      >>>

      <<< custom name=foo bar=baz
      some opaque content
      >>>
      """

      {:ok, blocks} = Mult.Container.parse(input)
      assert length(blocks) == 2
      custom = Enum.at(blocks, 1)
      assert custom.kind == "custom"
      assert custom.attrs["bar"] == "baz"
      assert custom.body =~ "opaque content"
    end

    test "ignores container comments (;;)" do
      input = """
      ;; This is a comment
      <<< meta lang=toml
      id = "test"
      >>>
      ;; Another comment
      """

      {:ok, blocks} = Mult.Container.parse(input)
      assert length(blocks) == 1
    end

    test "parses quoted attribute values" do
      input = """
      <<< meta lang=toml purpose="demonstrate extension"
      id = "test"
      >>>
      """

      {:ok, blocks} = Mult.Container.parse(input)
      assert hd(blocks).attrs["purpose"] == "demonstrate extension"
    end
  end

  # ── TOML parser ────────────────────────────────────────────────

  describe "Mult.Toml.parse/1" do
    test "parses basic key/value pairs" do
      {:ok, result} = Mult.Toml.parse(~s(name = "hello"\ncount = 42))
      assert result["name"] == "hello"
      assert result["count"] == 42
    end

    test "parses tables" do
      input = """
      [server]
      host = "localhost"
      port = 8080
      """

      {:ok, result} = Mult.Toml.parse(input)
      assert result["server"]["host"] == "localhost"
      assert result["server"]["port"] == 8080
    end

    test "parses arrays" do
      {:ok, result} = Mult.Toml.parse(~s(tags = ["a", "b", "c"]))
      assert result["tags"] == ["a", "b", "c"]
    end

    test "parses booleans" do
      {:ok, result} = Mult.Toml.parse("enabled = true\ndisabled = false")
      assert result["enabled"] == true
      assert result["disabled"] == false
    end

    test "parses dotted keys" do
      {:ok, result} = Mult.Toml.parse(~s(a.b.c = "deep"))
      assert result["a"]["b"]["c"] == "deep"
    end

    test "parses array of tables" do
      input = """
      [[items]]
      name = "first"

      [[items]]
      name = "second"
      """

      {:ok, result} = Mult.Toml.parse(input)
      assert length(result["items"]) == 2
      assert Enum.at(result["items"], 0)["name"] == "first"
      assert Enum.at(result["items"], 1)["name"] == "second"
    end

    test "handles string escapes" do
      {:ok, result} = Mult.Toml.parse(~s(s = "line1\\nline2\\ttab"))
      assert result["s"] == "line1\nline2\ttab"
    end

    test "parses floats" do
      {:ok, result} = Mult.Toml.parse("pi = 3.14")
      assert result["pi"] == 3.14
    end

    test "handles comments" do
      {:ok, result} = Mult.Toml.parse("# comment\nkey = \"value\" # inline")
      assert result["key"] == "value"
    end
  end

  # ── SYAML parser ───────────────────────────────────────────────

  describe "Mult.Syaml.parse/1" do
    test "parses simple mapping" do
      {:ok, result} = Mult.Syaml.parse("name: hello\ncount: 42")
      assert result["name"] == "hello"
      assert result["count"] == 42
    end

    test "parses nested mapping" do
      input = """
      server:
        host: localhost
        port: 8080
      """

      {:ok, result} = Mult.Syaml.parse(input)
      assert result["server"]["host"] == "localhost"
      assert result["server"]["port"] == 8080
    end

    test "parses sequences" do
      input = """
      items:
        - first
        - second
        - third
      """

      {:ok, result} = Mult.Syaml.parse(input)
      assert result["items"] == ["first", "second", "third"]
    end

    test "parses booleans and null" do
      input = """
      enabled: true
      disabled: false
      nothing: null
      tilde: ~
      """

      {:ok, result} = Mult.Syaml.parse(input)
      assert result["enabled"] == true
      assert result["disabled"] == false
      assert result["nothing"] == nil
      assert result["tilde"] == nil
    end

    test "rejects tags" do
      {:error, msg} = Mult.Syaml.parse("value: !ruby/object foo")
      assert msg =~ "forbids tags"
    end

    test "rejects anchors" do
      {:error, msg} = Mult.Syaml.parse("value: &anchor foo")
      assert msg =~ "forbids anchors"
    end

    test "rejects flow style" do
      {:error, msg} = Mult.Syaml.parse("value: {key: val}")
      assert msg =~ "forbids flow style"
    end

    test "rejects multi-document streams" do
      {:error, msg} = Mult.Syaml.parse("---\nkey: value")
      assert msg =~ "forbids multi-document"
    end
  end

  # ── TSV parser ─────────────────────────────────────────────────

  describe "Mult.Tsv.parse/1" do
    test "parses basic TSV" do
      input = "id\tname\n1\tAlice\n2\tBob"
      {:ok, rows} = Mult.Tsv.parse(input)
      assert length(rows) == 2
      assert hd(rows)["id"] == "1"
      assert hd(rows)["name"] == "Alice"
    end

    test "handles missing cells" do
      input = "id\tname\tborn\n1\tAlice"
      {:ok, rows} = Mult.Tsv.parse(input)
      assert hd(rows)["born"] == ""
    end

    test "handles escape sequences" do
      input = "col\nval\\twith\\ttabs"
      {:ok, rows} = Mult.Tsv.parse(input)
      assert hd(rows)["col"] == "val\twith\ttabs"
    end

    test "roundtrips through encode/parse" do
      rows = [%{"id" => "1", "name" => "Alice"}, %{"id" => "2", "name" => "Bob"}]
      encoded = Mult.Tsv.encode(rows, ["id", "name"])
      {:ok, parsed} = Mult.Tsv.parse(encoded)
      assert parsed == rows
    end
  end

  # ── Schema validation ─────────────────────────────────────────

  describe "Mult.Schema.validate/2" do
    test "validates object with required keys" do
      schema = %{"type" => "object", "required" => ["name", "age"]}
      assert :ok = Mult.Schema.validate(%{"name" => "Alice", "age" => 30}, schema)

      {:error, errors} = Mult.Schema.validate(%{"name" => "Alice"}, schema)
      assert length(errors) == 1
      assert hd(errors) =~ "Missing required key 'age'"
    end

    test "validates nested property types" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "int"}
        }
      }

      assert :ok = Mult.Schema.validate(%{"name" => "Alice", "age" => 30}, schema)

      {:error, errors} = Mult.Schema.validate(%{"name" => "Alice", "age" => "thirty"}, schema)
      assert length(errors) > 0
    end

    test "validates arrays" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}
      assert :ok = Mult.Schema.validate(["a", "b", "c"], schema)

      {:error, _} = Mult.Schema.validate(["a", 1, "c"], schema)
    end

    test "validates ULID format" do
      schema = %{"type" => "ulid"}
      assert :ok = Mult.Schema.validate("01HZY8R1J9R8H3Q9CNEC6R4W5Z", schema)
      {:error, _} = Mult.Schema.validate("not-a-ulid", schema)
      {:error, _} = Mult.Schema.validate("01hzy8r1j9r8h3q9cnec6r4w5z", schema)
    end

    test "validates semver format" do
      schema = %{"type" => "semver"}
      assert :ok = Mult.Schema.validate("1.2.3", schema)
      assert :ok = Mult.Schema.validate("1.0.0-alpha", schema)
      {:error, _} = Mult.Schema.validate("1.2", schema)
    end

    test "validates date format" do
      schema = %{"type" => "date"}
      assert :ok = Mult.Schema.validate("2026-02-03", schema)
      {:error, _} = Mult.Schema.validate("not-a-date", schema)
      {:error, _} = Mult.Schema.validate("2026-13-01", schema)
    end

    test "validates enum constraint" do
      schema = %{"type" => "string", "enum" => ["low", "medium", "high"]}
      assert :ok = Mult.Schema.validate("high", schema)
      {:error, _} = Mult.Schema.validate("critical", schema)
    end

    test "validates pattern constraint" do
      schema = %{"type" => "string", "pattern" => "^[a-z]+$"}
      assert :ok = Mult.Schema.validate("hello", schema)
      {:error, _} = Mult.Schema.validate("Hello", schema)
    end

    test "validates min_len/max_len" do
      schema = %{"type" => "string", "min_len" => 2, "max_len" => 5}
      assert :ok = Mult.Schema.validate("hi", schema)
      {:error, _} = Mult.Schema.validate("x", schema)
      {:error, _} = Mult.Schema.validate("toolong", schema)
    end

    test "validates table type" do
      schema = %{
        "type" => "table",
        "columns" => [
          %{"name" => "id", "type" => "int"},
          %{"name" => "name", "type" => "string"},
          %{"name" => "born", "type" => "date", "optional" => true}
        ]
      }

      rows = [
        %{"id" => "1", "name" => "Alice", "born" => "2000-01-01"},
        %{"id" => "2", "name" => "Bob", "born" => ""}
      ]

      assert :ok = Mult.Schema.validate(rows, schema)
    end

    test "validates map type" do
      schema = %{
        "type" => "map",
        "keys" => %{"type" => "string"},
        "values" => %{"type" => "string"}
      }

      assert :ok = Mult.Schema.validate(%{"a" => "b", "c" => "d"}, schema)
    end
  end

  # ── Full document parse + validate ─────────────────────────────

  describe "Mult.parse/1 and Mult.validate/1" do
    test "parses and validates the sample.mult file" do
      {:ok, doc} = Mult.parse_file("sample.mult")

      assert doc.meta["id"] == "com.example.mult-demo"
      assert doc.meta["title"] == "MULT/1 Demonstration Document"
      assert length(doc.blocks) == 11
      assert map_size(doc.schemas) == 4
      assert doc.errors == []

      assert :ok = Mult.validate(doc)
    end

    test "rejects document without meta as first block" do
      input = """
      <<< md name=readme
      # Hello
      >>>
      """

      {:error, msg} = Mult.parse(input)
      assert msg =~ "First block must be 'meta'"
    end

    test "rejects empty document" do
      {:error, msg} = Mult.parse("")
      assert msg =~ "no blocks"
    end

    test "can look up blocks by name" do
      {:ok, doc} = Mult.parse_file("sample.mult")

      block = Mult.get_block_by_name(doc, "readme")
      assert block.kind == "md"

      {:ok, value} = Mult.get_decoded(doc, "artifact")
      assert value["kind"] == "document"
    end

    test "can get blocks by kind" do
      {:ok, doc} = Mult.parse_file("sample.mult")

      schemas = Mult.get_blocks(doc, "schema")
      assert length(schemas) == 4

      tsvs = Mult.get_blocks(doc, "tsv")
      assert length(tsvs) == 1
    end

    test "detects schema validation failure" do
      input = """
      <<< meta lang=toml
      id = "test"
      >>>

      <<< schema name=myschema lang=toml
      type = "object"
      required = ["name"]
      >>>

      <<< toml name=data schema="myschema"
      other = "no name key"
      >>>
      """

      {:ok, doc} = Mult.parse(input)
      {:error, errors} = Mult.validate(doc)
      assert length(errors) > 0
      assert hd(errors) =~ "Missing required key 'name'"
    end
  end

  # ── Encoder ────────────────────────────────────────────────────

  describe "Mult.encode/1" do
    test "roundtrips a simple document" do
      input = """
      <<< meta lang=toml
      id = "test"
      >>>

      <<< md name=readme
      # Hello world
      >>>
      """

      {:ok, doc} = Mult.parse(input)
      output = Mult.encode(doc)

      # Parse again and verify
      {:ok, doc2} = Mult.parse(output)
      assert length(doc2.blocks) == 2
      assert doc2.meta["id"] == "test"
    end
  end

  # ── TOML encoder ───────────────────────────────────────────────

  describe "Mult.Toml.encode/1" do
    test "encodes a flat map" do
      result = Mult.Toml.encode(%{"name" => "test", "count" => 42})
      assert result =~ "count = 42"
      assert result =~ ~s(name = "test")
    end

    test "encodes nested tables" do
      result = Mult.Toml.encode(%{"server" => %{"host" => "localhost", "port" => 8080}})
      assert result =~ "[server]"
      assert result =~ ~s(host = "localhost")
    end
  end

  # ── SYAML encoder ──────────────────────────────────────────────

  describe "Mult.Syaml.encode/1" do
    test "encodes a mapping" do
      result = Mult.Syaml.encode(%{"name" => "test", "count" => 42})
      assert result =~ "count: 42"
      assert result =~ "name: test"
    end

    test "encodes a list" do
      result = Mult.Syaml.encode(%{"items" => ["a", "b"]})
      assert result =~ "- a"
      assert result =~ "- b"
    end
  end
end
