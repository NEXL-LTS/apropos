module Muninn
  # The process/PATH boundary (PRD §8.2), used by `doctor` to inspect the host.
  # Isolating executable lookup and version probing behind an injectable adapter
  # keeps doctor's logic unit-testable with a fake while `Real` is the only code
  # that touches `Process`.
  abstract class Environment
    # Resolve `command` on `PATH`, or nil when it is not found.
    abstract def which(command : String) : String?

    # Run `command args...` and return its captured stdout on success, or nil on
    # a non-zero exit or a launch failure (e.g. the command is absent).
    abstract def run_capture(command : String, args : Array(String)) : String?

    # The production adapter: the only place `Process` is called for doctor.
    class Real < Environment
      def which(command : String) : String?
        Process.find_executable(command)
      end

      def run_capture(command : String, args : Array(String)) : String?
        stdout = IO::Memory.new
        status = Process.run(command, args, output: stdout, error: Process::Redirect::Close)
        status.success? ? stdout.to_s : nil
      rescue
        nil
      end
    end
  end
end
