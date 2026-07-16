require "../../spec_helper"

private def parse(json : String) : Muninn::Hook::Payload
  Muninn::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe Muninn::Hook::Payload do
  describe ".parse" do
    it "parses a PreToolUse Edit payload" do
      json = {
        session_id:      "abc123",
        tool_name:       "Edit",
        cwd:             "/repo",
        transcript_path: "/home/u/.claude/x.jsonl",
        tool_input:      {file_path: "app/jobs/m.cr", old_string: "a", new_string: "b"},
      }.to_json

      payload = parse(json)
      payload.session_id.should eq("abc123")
      payload.tool_name.should eq("Edit")
      payload.cwd.should eq("/repo")
      payload.file_path.should eq("app/jobs/m.cr")
    end

    it "returns nil for malformed JSON (fail open)" do
      Muninn::Hook::Payload.parse("{not json").should be_nil
    end

    it "tolerates a payload with no tool_input at all" do
      payload = parse(%({"session_id":"s"}))
      payload.file_path.should be_nil
      payload.written_contents.should be_empty
    end

    it "ignores unknown top-level and tool_input keys" do
      json = %({"future_field":1,"tool_input":{"file_path":"a.cr","extra":true}})
      parse(json).file_path.should eq("a.cr")
    end
  end

  describe "#written_contents" do
    it "returns a Write's content" do
      json = %({"tool_input":{"file_path":"a.cr","content":"hello"}})
      parse(json).written_contents.should eq(["hello"])
    end

    it "returns an Edit's new_string" do
      json = %({"tool_input":{"file_path":"a.cr","new_string":"edited"}})
      parse(json).written_contents.should eq(["edited"])
    end

    it "collects every new_string of a batch edit" do
      json = %({"tool_input":{"file_path":"a.cr","edits":[{"new_string":"x"},{"new_string":"y"},{}]}})
      parse(json).written_contents.should eq(["x", "y"])
    end
  end
end
