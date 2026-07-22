# Binary entry point. Intentionally trivial: all logic lives in `AgentApropos::CLI`
# so it is unit-testable with injected IO. This delegating line is exercised
# end-to-end by spec/integration and excluded from the line-coverage count
# (see the kcov exclusion in the Makefile / CI).
require "./agent_apropos/cli"

exit AgentApropos::CLI.run(ARGV)
