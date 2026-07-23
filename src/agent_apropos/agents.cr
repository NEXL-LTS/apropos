require "./agents/agent"
require "./agents/claude"
require "./agents/opencode"
require "./agents/gemini"
require "./agents/copilot"

module AgentApropos
  module Agents
    # Every CLI agent `agent-apropos` knows how to wire hooks for, in a
    # stable order (auto-detect and `doctor` reporting both iterate this).
    # Extend this array as more agents (Codex, Cursor CLI, ...) land — no
    # other file needs a new per-agent branch.
    ALL = [
      Claude.new,
      OpenCode.new,
      Gemini.new,
      Copilot.new,
    ] of Agent

    # The `--tool <name>` values `Init`/`Doctor` know how to wire, for
    # validating `--tool` flags and auto-detect probing.
    def self.names : Set(String)
      ALL.map(&.name).to_set
    end
  end
end
