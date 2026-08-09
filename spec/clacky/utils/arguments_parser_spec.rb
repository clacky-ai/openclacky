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

    context "with double-serialized parameters" do
      # Some LLMs emit array/object params as a JSON *string* (e.g.
      # {"task":"[\"a\",\"b\"]"}) instead of native JSON. End-to-end check that
      # parse_and_validate unwraps one serialization layer.
      let(:todo_registry) do
        registry = instance_double("Clacky::ToolRegistry")
        tool = double("TodoTool",
          name: "todo_manager",
          description: "todo",
          parameters: {
            required: ["action"],
            properties: {
              "action" => { "type" => "string" },
              "task" => { "description" => "task" },
              "id" => { "description" => "id" }
            }
          }
        )
        allow(registry).to receive(:get).with("todo_manager").and_return(tool)
        registry
      end

      it "unwraps a double-serialized array parameter" do
        call = { name: "todo_manager", arguments: '{"action":"add","task":"[\"a\",\"b\",\"c\"]"}' }

        result = described_class.parse_and_validate(call, todo_registry)

        expect(result[:task]).to eq(%w[a b c])
      end

      it "unwraps a double-serialized integer array parameter" do
        call = { name: "todo_manager", arguments: '{"action":"complete","id":"[1,2,3]"}' }

        result = described_class.parse_and_validate(call, todo_registry)

        expect(result[:id]).to eq([1, 2, 3])
      end

      it "unwraps a double-serialized object parameter" do
        call = { name: "todo_manager", arguments: '{"action":"add","task":"{\"x\":1,\"y\":[2,3]}"}' }

        result = described_class.parse_and_validate(call, todo_registry)

        expect(result[:task]).to eq("x" => 1, "y" => [2, 3])
      end

      it "preserves a genuine single-string task" do
        call = { name: "todo_manager", arguments: '{"action":"add","task":"完成季度报告"}' }

        result = described_class.parse_and_validate(call, todo_registry)

        expect(result[:task]).to eq("完成季度报告")
      end
    end
  end

  describe ".undouble_serialize_args" do
    it "unwraps a stringified JSON array into a native Array" do
      result = described_class.undouble_serialize_args(task: '["a","b","c"]')

      expect(result[:task]).to eq(%w[a b c])
    end

    it "unwraps a stringified JSON object into a native Hash" do
      result = described_class.undouble_serialize_args(meta: '{"x":1,"y":[2,3]}')

      expect(result[:meta]).to eq("x" => 1, "y" => [2, 3])
    end

    it "preserves a plain string value" do
      result = described_class.undouble_serialize_args(task: "完成季度报告")

      expect(result[:task]).to eq("完成季度报告")
    end

    it "preserves a string that starts with [ but is not valid JSON" do
      result = described_class.undouble_serialize_args(task: "[未闭合")

      expect(result[:task]).to eq("[未闭合")
    end

    it "preserves a string that starts with { but is not valid JSON" do
      result = described_class.undouble_serialize_args(task: "{未闭合")

      expect(result[:task]).to eq("{未闭合")
    end

    it "preserves non-string values" do
      result = described_class.undouble_serialize_args(a: 1, b: nil, c: %w[x y], d: { k: 1 })

      expect(result).to eq(a: 1, b: nil, c: %w[x y], d: { k: 1 })
    end

    it "does not recurse into array elements" do
      # A string element that merely looks like JSON (e.g. file content) must
      # stay a string; otherwise legitimate string payloads get corrupted.
      result = described_class.undouble_serialize_args(items: ['["a","b"]', "[1,2]"])

      expect(result[:items]).to eq(['["a","b"]', "[1,2]"])
    end

    it "does not recurse into nested hash values" do
      # Only top-level values are unwrapped. A stringified JSON nested inside a
      # native object is preserved verbatim by design.
      result = described_class.undouble_serialize_args(meta: { k: '["a","b"]' })

      expect(result[:meta]).to eq(k: '["a","b"]')
    end

    it "leaves sibling values untouched while unwrapping one" do
      result = described_class.undouble_serialize_args(action: "add", task: '["a","b"]', id: 5)

      expect(result).to eq(action: "add", task: %w[a b], id: 5)
    end

    it "handles leading/trailing whitespace around JSON-looking strings" do
      result = described_class.undouble_serialize_args(task: '  ["a","b"]  ')

      expect(result[:task]).to eq(%w[a b])
    end

    it "returns an empty hash unchanged" do
      expect(described_class.undouble_serialize_args({})).to eq({})
    end
  end

  describe ".repair_json (private method)" do
    it "is tested indirectly through parse_and_validate" do
      # The repair_json method is private, so we test it through the public interface
      # All the XML contamination tests above exercise this method
      expect(true).to be true
    end
  end
end
