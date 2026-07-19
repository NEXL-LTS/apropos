require "../spec_helper"

# Split and cast in one step; `.as` fails the example clearly if the block is
# unexpectedly absent (ameba forbids `not_nil!`).
private def split_doc(text : String) : {Apropos::Frontmatter, String}
  frontmatter, body = Apropos::Frontmatter.split(text)
  {frontmatter.as(Apropos::Frontmatter), body}
end

describe Apropos::Frontmatter do
  describe ".split" do
    it "returns no frontmatter for a doc without a leading fence" do
      fm, body = Apropos::Frontmatter.split("# Title\n\nprose\n")
      fm.should be_nil
      body.should eq("# Title\n\nprose\n")
    end

    it "separates the frontmatter block from the body, preserving body bytes" do
      fm, body = split_doc("---\npaths: [\"src/**\"]\n---\n# Rule\n\nbody\n")
      fm.paths.should eq(["src/**"])
      body.should eq("# Rule\n\nbody\n")
    end

    it "handles an empty frontmatter block as reference-only" do
      fm, body = split_doc("---\n---\nbody\n")
      fm.reference_only?.should be_true
      body.should eq("body\n")
    end

    it "handles a closing fence at end-of-file with no trailing body" do
      fm, body = split_doc("---\nskill: true\n---")
      fm.skill?.should be_true
      body.should eq("")
    end

    it "tolerates CRLF line endings and trailing spaces on the fence" do
      fm, body = split_doc("--- \r\npaths: [\"a/**\"]\r\n--- \r\nbody\r\n")
      fm.paths.should eq(["a/**"])
      body.should eq("body\r\n")
    end

    it "raises on an unterminated frontmatter block" do
      expect_raises(Apropos::Frontmatter::Error, /unterminated/) do
        Apropos::Frontmatter.split("---\npaths: [\"a\"]\nno closing fence\n")
      end
    end
  end

  describe ".parse" do
    it "returns an empty frontmatter for blank or comment-only YAML" do
      Apropos::Frontmatter.parse("").reference_only?.should be_true
      Apropos::Frontmatter.parse("# just a comment\n").reference_only?.should be_true
    end

    it "reads all known keys" do
      fm = Apropos::Frontmatter.parse(<<-YAML)
        paths: ["app/jobs/**", "lib/**"]
        contents: ['\\.transaction\\b']
        skill: true
        description: "Use when doing X"
        YAML
      fm.paths.should eq(["app/jobs/**", "lib/**"])
      fm.contents.should eq(["\\.transaction\\b"])
      fm.skill?.should be_true
      fm.description.should eq("Use when doing X")
      fm.unknown_keys.should be_empty
    end

    it "collects unknown keys, sorted, for the linter" do
      fm = Apropos::Frontmatter.parse("zebra: 1\napple: 2\npaths: [\"a\"]\n")
      fm.unknown_keys.should eq(["apple", "zebra"])
    end

    it "treats explicitly-null values as absent" do
      fm = Apropos::Frontmatter.parse("paths:\ncontents:\nskill:\ndescription:\n")
      fm.paths.should be_empty
      fm.contents.should be_empty
      fm.skill?.should be_false
      fm.description.should be_nil
    end

    it "raises on invalid YAML" do
      expect_raises(Apropos::Frontmatter::Error, /invalid YAML/) do
        Apropos::Frontmatter.parse("paths: [unterminated\n")
      end
    end

    it "raises when the top level is not a mapping" do
      expect_raises(Apropos::Frontmatter::Error, /must be a mapping/) do
        Apropos::Frontmatter.parse("just a scalar")
      end
    end

    it "raises when paths is not a list" do
      expect_raises(Apropos::Frontmatter::Error, /`paths` must be a list/) do
        Apropos::Frontmatter.parse("paths: nope\n")
      end
    end

    it "raises when a paths entry is not a string" do
      expect_raises(Apropos::Frontmatter::Error, /`paths` entries must be strings/) do
        Apropos::Frontmatter.parse("paths: [1, 2]\n")
      end
    end

    it "raises when contents is not a list" do
      expect_raises(Apropos::Frontmatter::Error, /`contents` must be a list/) do
        Apropos::Frontmatter.parse("contents: nope\n")
      end
    end

    it "raises when skill is not a boolean" do
      expect_raises(Apropos::Frontmatter::Error, /`skill` must be a boolean/) do
        Apropos::Frontmatter.parse("skill: yesterday\n")
      end
    end

    it "raises when description is not a string" do
      expect_raises(Apropos::Frontmatter::Error, /`description` must be a string/) do
        Apropos::Frontmatter.parse("description: [1]\n")
      end
    end
  end

  describe "#reference_only?" do
    it "is true only when there is no trigger and no skill" do
      Apropos::Frontmatter.new.reference_only?.should be_true
    end

    it "is false when any path, content, or skill flag is present" do
      Apropos::Frontmatter.new(paths: ["a/**"]).reference_only?.should be_false
      Apropos::Frontmatter.new(contents: ["x"]).reference_only?.should be_false
      Apropos::Frontmatter.new(skill: true).reference_only?.should be_false
    end
  end
end
