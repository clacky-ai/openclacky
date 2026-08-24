# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/arguments_parser"

RSpec.describe Clacky::Utils::ArgumentsParser do
  let(:tool_registry) do
    registry = instance_double("Clacky::ToolRegistry")
    
    # Mock a tool with required and optional parameters
    tool = double("Tool",
      name: "file_reader",
      description: "Read contents of a file",
      parameters: {
        required: ["path"],
        properties: {
          "path" => { description: "File path" },
          "start_line" => { description: "Start line number" },
          "end_line" => { description: "End line number" },
          "max_lines" => { description: "Maximum lines to read" }
        }
      }
    )
    
    allow(registry).to receive(:get).with("file_reader").and_return(tool)
    registry
  end

  describe ".parse_and_validate" do
    context "with valid JSON" do
      it "parses and validates correctly" do
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "start_line": 10, "end_line": 20}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
        expect(result[:end_line]).to eq(20)
      end

      it "filters out unknown parameters" do
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "unknown_param": "value"}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result).not_to have_key(:unknown_param)
      end
    end

    context "with XML contamination" do
      it "repairs JSON contaminated with XML closing tags" do
        # Simulates: {"path": "test.rb", "start_line":10</parameter>, "end_line": 20}
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "start_line":10</parameter>, "end_line": 20}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
        expect(result[:end_line]).to eq(20)
      end

      it "repairs JSON with XML parameter tags and newlines" do
        # Simulates: {"path": "test.rb", "start_line":315</parameter>\n<parameter name="end_line"> 330}
        # Using double quotes to allow \n to be interpreted as newline
        call = {
          name: "file_reader",
          arguments: "{\"path\": \"test.rb\", \"start_line\":315</parameter>\n<parameter name=\"end_line\"> 330}"
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(315)
        expect(result[:end_line]).to eq(330)
      end

      it "handles real-world example from error log" do
        # Actual example from session log
        call = {
          name: "file_reader",
          arguments: "{\"path\": \"lib/clacky/ui2/components/modal_component.rb\", \"start_line\":315</parameter>\n<parameter name=\"end_line\": 330}"
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("lib/clacky/ui2/components/modal_component.rb")
        expect(result[:start_line]).to eq(315)
        expect(result[:end_line]).to eq(330)
      end

      it "removes multiple XML tags" do
        call = {
          name: "file_reader",
          arguments: "{\"path\": \"test.rb\"</parameter>\n<parameter name=\"start_line\"> 10</parameter>\n<parameter name=\"end_line\"> 20}"
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
        expect(result[:end_line]).to eq(20)
      end
    end

    context "with incomplete JSON" do
      it "completes unclosed braces" do
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb"'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
      end

      it "handles truncated JSON with missing closing brace" do
        # Note: Completing unclosed strings in the middle of JSON is complex
        # and rarely happens in practice. We focus on missing closing braces.
        call = {
          name: "file_reader",
          arguments: '{"path": "test.rb", "start_line": 10'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:path]).to eq("test.rb")
        expect(result[:start_line]).to eq(10)
      end

      it "handles literal backslash-n instead of real newline (session JSON format)" do
        # Real-world case from session 2026-04-10-11-45-34-b8099a0e.json line 821
        # When session JSON is saved/loaded, newlines become literal \n (backslash+n)
        # AND successfully parsed JSON may have malformed keys containing XML tags
        call = {
          name: "file_reader",
          arguments: '{"end_line\":550</parameter>\n<parameter name=\"path":"openclacky/lib/clacky/web/index.html","start_line":400}'
        }
        
        result = described_class.parse_and_validate(call, tool_registry)
        
        expect(result[:end_line]).to eq(550)
        expect(result[:path]).to eq("openclacky/lib/clacky/web/index.html")
        expect(result[:start_line]).to eq(400)
      end
    end

    context "with missing required parameters" do
      it "raises error for missing required params" do
        call = {
          name: "file_reader",
          arguments: '{"start_line": 10}'
        }
        
        expect {
          described_class.parse_and_validate(call, tool_registry)
        }.to raise_error(Clacky::Utils::MissingRequiredParamsError, /Missing required parameters: path/)
      end
    end

    context "with completely invalid JSON" do
      it "raises helpful error" do
        call = {
          name: "file_reader",
          arguments: 'totally invalid {][ json'
        }
        
        expect {
          described_class.parse_and_validate(call, tool_registry)
        }.to raise_error(StandardError, /Failed to parse arguments.*file_reader/)
      end
    end
  end

  # ── schema-aware undouble-serialization ────────────────────────────────────
  # Some LLMs (e.g. glm-5.2) emit array/object params as a JSON *string*
  # instead of a native value. undouble_serialize_args recovers one layer,
  # guided by the param's declared schema type so that string params are
  # never corrupted. See PR #457.
  describe "undouble-serialization recovery" do
    # Tool whose params cover the key schema types we need to exercise.
    let(:typed_registry) do
      registry = instance_double("Clacky::ToolRegistry")
      tool = double("TypedTool",
        name: "typed_tool",
        description: "Tool with typed array/object/string params",
        parameters: {
          required: ["action"],
          properties: {
            "action"  => { "type" => "string",  "description" => "Action" },
            "items"   => { "type" => "array",   "description" => "Array param" },
            "config"  => { "type" => "object",  "description" => "Object param" },
            "content" => { "type" => "string",  "description" => "String param" }
          }
        }
      )
      allow(registry).to receive(:get).with("typed_tool").and_return(tool)
      registry
    end

    context "when array/object params are accidentally double-serialized" do
      it "unwraps an array param that arrived as a JSON string" do
        call = { name: "typed_tool", arguments: '{"action":"add","items":"[\"a\",\"b\"]"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:items]).to eq(["a", "b"])
        expect(result[:items]).to be_an(Array)
      end

      it "unwraps an object param that arrived as a JSON string" do
        call = { name: "typed_tool", arguments: '{"action":"add","config":"{\"key\":\"val\"}"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:config]).to eq(key: "val")
        expect(result[:config]).to be_a(Hash)
      end

      it "unwraps an array-of-objects param" do
        call = { name: "typed_tool", arguments: '{"action":"add","items":"[{\"x\":1},{\"y\":2}]"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:items]).to eq([{ x: 1 }, { y: 2 }])
      end
    end

    context "symbolize_names consistency" do
      it "keeps unwrapped object keys as Symbols, matching the outer JSON.parse" do
        # The outer JSON.parse(call[:arguments], symbolize_names: true) turns
        # top-level keys into Symbols.  The inner JSON.parse inside
        # undouble_serialize_args must do the same for the *unwrapped* Hash,
        # otherwise downstream code gets an inconsistent mix of Symbol/String keys.
        call = { name: "typed_tool", arguments: '{"action":"add","config":"{\"port\":8080,\"host\":\"0.0.0.0\"}"}' }
        result = described_class.parse_and_validate(call, typed_registry)

        expect(result[:config]).to eq(port: 8080, host: "0.0.0.0")
        # Explicit assertion: every key in the unwrapped Hash must be a Symbol.
        expect(result[:config].keys).to all(be_a(Symbol))
      end

      it "keeps nested Hash keys as Symbols too" do
        call = { name: "typed_tool", arguments: '{"action":"add","config":"{\"outer\":{\"inner\":42}}"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:config][:outer]).to eq(inner: 42)
        expect(result[:config][:outer].keys).to all(be_a(Symbol))
      end
    end

    context "type-match guard" do
      it "leaves an array-typed param untouched when it receives a JSON object string" do
        # Without the guard, {"k":"v"} would be silently coerced to a Hash,
        # changing the param's type from String→Array (intended) to
        # String→Hash (wrong).  The guard preserves the original value.
        call = { name: "typed_tool", arguments: '{"action":"add","items":"{\"k\":\"v\"}"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:items]).to eq("{\"k\":\"v\"}")
        expect(result[:items]).to be_a(String)
        expect(result[:items]).not_to be_an(Array)
      end

      it "leaves an object-typed param untouched when it receives a JSON array string" do
        call = { name: "typed_tool", arguments: '{"action":"add","config":"[1,2,3]"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:config]).to eq("[1,2,3]")
        expect(result[:config]).to be_a(String)
        expect(result[:config]).not_to be_a(Hash)
      end
    end

    context "string-param protection (the #453 revert concern)" do
      it "preserves a string param whose value happens to be valid JSON object text" do
        call = { name: "typed_tool", arguments: '{"action":"add","content":"{\"name\":\"test\"}"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:content]).to eq("{\"name\":\"test\"}")
      end

      it "preserves a string param whose value happens to be valid JSON array text" do
        call = { name: "typed_tool", arguments: '{"action":"add","content":"[1,2,3]"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:content]).to eq("[1,2,3]")
      end
    end

    context "edge cases" do
      it "handles an empty array string" do
        call = { name: "typed_tool", arguments: '{"action":"add","items":"[]"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:items]).to eq([])
      end

      it "handles an empty object string" do
        call = { name: "typed_tool", arguments: '{"action":"add","config":"{}"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:config]).to eq({})
      end

      it "leaves a non-JSON string value untouched" do
        call = { name: "typed_tool", arguments: '{"action":"add","items":"not-json"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:items]).to eq("not-json")
      end

      it "leaves an unclosed JSON string untouched" do
        call = { name: "typed_tool", arguments: '{"action":"add","items":"[1,2"}' }
        result = described_class.parse_and_validate(call, typed_registry)
        expect(result[:items]).to eq("[1,2")
      end
    end
  end

  describe ".repair_json" do
    it "closes a truncated object" do
      repaired = described_class.repair_json('{"question":"Which one?"')
      expect(JSON.parse(repaired)).to eq("question" => "Which one?")
    end

    it "closes a truncated nested array in opening order" do
      repaired = described_class.repair_json('{"questions":[{"question":"Pick","options":["a","b"')
      parsed = JSON.parse(repaired)

      expect(parsed["questions"].first["options"]).to eq(%w[a b])
    end

    it "closes a truncation that cuts mid-string" do
      repaired = described_class.repair_json('{"questions":[{"question":"Pick","options":["a","b')
      parsed = JSON.parse(repaired)

      expect(parsed["questions"].first["options"]).to eq(%w[a b])
    end

    it "ignores brackets inside string values" do
      repaired = described_class.repair_json('{"question":"use [] or {} ?"')
      expect(JSON.parse(repaired)).to eq("question" => "use [] or {} ?")
    end

    it "tracks escaped backslashes inside a string value" do
      repaired = described_class.repair_json('{"path":"C:\\\\tmp"')
      expect(JSON.parse(repaired)).to eq("path" => 'C:\tmp')
    end

    it "leaves balanced JSON unchanged" do
      source = '{"questions":[{"question":"Pick"}]}'
      expect(described_class.repair_json(source)).to eq(source)
    end
  end
end
