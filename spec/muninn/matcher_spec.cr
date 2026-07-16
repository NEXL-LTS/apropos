require "../spec_helper"

describe Muninn::Matcher do
  describe ".path_match?" do
    it "matches a ** glob across any directory depth" do
      Muninn::Matcher.path_match?("app/jobs/**", "app/jobs/mailer.cr").should be_true
      Muninn::Matcher.path_match?("app/jobs/**", "app/jobs/sub/deep.cr").should be_true
    end

    it "does not match a path outside the glob" do
      Muninn::Matcher.path_match?("app/jobs/**", "app/models/user.cr").should be_false
    end

    it "honours a single * as a single segment" do
      Muninn::Matcher.path_match?("src/*.cr", "src/cli.cr").should be_true
      Muninn::Matcher.path_match?("src/*.cr", "src/muninn/cli.cr").should be_false
    end
  end

  describe ".any_path_match?" do
    it "is true when any pattern matches" do
      Muninn::Matcher.any_path_match?(["lib/**", "spec/**"], "spec/a_spec.cr").should be_true
    end

    it "is false when no pattern matches" do
      Muninn::Matcher.any_path_match?(["lib/**", "spec/**"], "src/x.cr").should be_false
    end

    it "is false for an empty pattern list" do
      Muninn::Matcher.any_path_match?([] of String, "anything.cr").should be_false
    end
  end

  describe ".content_match?" do
    it "matches content against a PCRE2 regex source" do
      Muninn::Matcher.content_match?("\\btransaction\\b", "db.transaction do").should be_true
    end

    it "does not match when the pattern is absent" do
      Muninn::Matcher.content_match?("\\btransaction\\b", "plain text").should be_false
    end

    it "raises a muninn error on an invalid regex source" do
      expect_raises(Muninn::Matcher::Error, /invalid regex/) do
        Muninn::Matcher.content_match?("(", "anything")
      end
    end
  end

  describe ".any_content_match?" do
    it "is true when any source matches" do
      Muninn::Matcher.any_content_match?(["nope", "wor.d"], "hello world").should be_true
    end

    it "is false for an empty source list" do
      Muninn::Matcher.any_content_match?([] of String, "content").should be_false
    end
  end
end
