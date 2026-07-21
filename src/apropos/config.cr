require "yaml"
require "./errors"
require "./filesystem"

module Apropos
  # Repo-level settings, read from `apropos.yml` at the repo root when
  # present. Optional — a repo with no `apropos.yml` gets every default
  # unchanged. Deliberately small: the only setting today is where the
  # convention docs live, so a repo can keep them outside its own tree (a
  # monorepo's shared docs, or — apropos's own e2e fixture — outside the
  # sample git repo entirely, so a CLI agent's auto-included directory
  # listing never reveals the mechanism under test).
  #
  # A malformed `apropos.yml` raises `Config::Error` rather than silently
  # falling back to the default — an authoring-time mistake should never be
  # indistinguishable from "no config" — so `generate`/`lint`/`match`/
  # `review` (which already propagate `Apropos::Error` and fail closed) need
  # no changes to handle it, and `hook`'s existing blanket rescue makes it
  # fail open there for free.
  module Config
    extend self

    class Error < Apropos::Error
    end

    FILENAME                = "apropos.yml"
    DEFAULT_CONVENTIONS_DIR = "docs/conventions"

    # The resolved conventions directory for `repo_root`: whatever
    # `apropos.yml`'s `conventions_dir` says — resolved against `repo_root`
    # when relative, used verbatim when absolute — or the default when the
    # file is absent or sets no `conventions_dir`.
    def conventions_dir(repo_root : Path, fs : Filesystem) : Path
      setting = conventions_dir_setting(repo_root, fs)
      return repo_root.join(DEFAULT_CONVENTIONS_DIR) unless setting

      path = Path[setting]
      path.absolute? ? path : repo_root.join(path)
    end

    private def conventions_dir_setting(repo_root : Path, fs : Filesystem) : String?
      text = fs.read?(repo_root.join(FILENAME).to_s)
      return nil unless text

      parsed =
        begin
          YAML.parse(text)
        rescue ex : YAML::ParseException
          raise Error.new("#{FILENAME} is not valid YAML: #{ex.message}")
        end
      hash = parsed.as_h?
      raise Error.new("#{FILENAME} must be a YAML mapping") unless hash

      value = parsed["conventions_dir"]?
      return nil unless value
      value.as_s? || raise Error.new("#{FILENAME}: conventions_dir must be a string")
    end
  end
end
