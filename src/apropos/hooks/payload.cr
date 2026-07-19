require "json"

module Apropos
  module Hook
    # The hook input contract, shared across every wired CLI agent's own wire
    # format (Claude Code's PreToolUse/PostToolUse payload; Gemini CLI's
    # AfterTool payload, whose `write_file`/`replace` tools happen to use the
    # same `file_path`/`content`/`new_string` argument names). Parsing is
    # deliberately *tolerant*: every field is optional, unknown keys are ignored,
    # and malformed JSON yields nil rather than raising — the hook path must fail
    # open, and the field names are the part of the contract most
    # exposed to upstream schema drift. The captured fixtures under
    # `spec/fixtures/hook_payloads/` — not this struct — are the authoritative
    # record of the field names; this parser just follows them.
    struct Payload
      include JSON::Serializable

      getter session_id : String?
      getter tool_name : String?
      getter cwd : String?
      getter tool_input : ToolInput?

      # One entry of a batch-edit tool input (a `MultiEdit`-style shape, absent
      # in some Claude Code versions). Only its `new_string` matters
      # for Layer 3 content matching.
      struct Edit
        include JSON::Serializable
        getter new_string : String?
      end

      struct ToolInput
        include JSON::Serializable

        getter file_path : String?
        getter content : String?    # Write
        getter new_string : String? # Edit
        getter edits : Array(Edit)? # batch edit
      end

      # Parse hook JSON from stdin, returning nil on anything malformed so the
      # caller emits nothing and exits 0.
      def self.parse(json : String) : Payload?
        from_json(json)
      rescue JSON::ParseException
        nil
      end

      # The edited file's path, if the payload carries one.
      def file_path : String?
        tool_input.try(&.file_path)
      end

      # Every piece of written content the payload exposes for Layer 3 matching:
      # a Write's `content`, an Edit's `new_string`, and each `new_string` of a
      # batch edit. Empty when none is present (the caller then reads the file
      # from disk).
      def written_contents : Array(String)
        input = tool_input
        return [] of String unless input

        pieces = [] of String
        input.content.try { |value| pieces << value }
        input.new_string.try { |value| pieces << value }
        input.edits.try(&.each { |edit| edit.new_string.try { |value| pieces << value } })
        pieces
      end
    end
  end
end
