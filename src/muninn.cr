# Binary entry point. Intentionally trivial: all logic lives in `Muninn::CLI`
# so it is unit-testable with injected IO. This delegating line is exercised
# end-to-end by spec/integration and excluded from the line-coverage count
# (see the kcov exclusion in the Makefile / CI).
require "./muninn/cli"

exit Muninn::CLI.run(ARGV)
