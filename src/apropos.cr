# Binary entry point. Intentionally trivial: all logic lives in `Apropos::CLI`
# so it is unit-testable with injected IO. This delegating line is exercised
# end-to-end by spec/integration and excluded from the line-coverage count
# (see the kcov exclusion in the Makefile / CI).
require "./apropos/cli"

exit Apropos::CLI.run(ARGV)
