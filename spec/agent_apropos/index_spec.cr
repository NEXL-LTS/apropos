require "../spec_helper"

private def convention(path : String, frontmatter : String, body : String = "body\n") : AgentApropos::Convention
  AgentApropos::Convention.parse(path, "---\n#{frontmatter}\n---\n#{body}")
end

describe AgentApropos::Index do
  describe ".build" do
    it "captures classification, triggers, and skill metadata per doc" do
      conventions = [
        convention("docs/conventions/a.md", %(paths: ["app/**"])),
        convention("docs/conventions/b.md", %(contents: ['\\bTODO\\b'])),
        convention("docs/conventions/workflows/c.md", %(skill: true\ndescription: "Use when C")),
      ]
      index = AgentApropos::Index.build(conventions)

      index.schema_version.should eq(AgentApropos::Index::SCHEMA_VERSION)
      index.docs.map(&.path).should eq([
        "docs/conventions/a.md",
        "docs/conventions/b.md",
        "docs/conventions/workflows/c.md",
      ])

      layer2 = index.docs[0]
      layer2.layer2?.should be_true
      layer2.layer3?.should be_false
      layer2.paths.should eq(["app/**"])

      layer3 = index.docs[1]
      layer3.layer3?.should be_true
      layer3.contents.should eq(["\\bTODO\\b"])

      skill = index.docs[2]
      skill.skill?.should be_true
      skill.description.should eq("Use when C")
      skill.hash.should eq(conventions[2].hash)
    end
  end

  describe "serialization" do
    it "round-trips through the deterministic document form" do
      conventions = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      document = AgentApropos::Index.build(conventions).to_document

      document.ends_with?("\n").should be_true
      document.should contain("\"schema_version\": 1")

      loaded = AgentApropos::Index.load(document)
      loaded.should_not be_nil
      loaded.as(AgentApropos::Index).docs.first.path.should eq("docs/conventions/a.md")
    end

    it "is byte-stable across builds" do
      conventions = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      AgentApropos::Index.build(conventions).to_document
        .should eq(AgentApropos::Index.build(conventions).to_document)
    end
  end

  describe ".load" do
    it "returns nil for malformed JSON" do
      AgentApropos::Index.load("{not json").should be_nil
    end

    it "returns nil on a schema-version mismatch (forces rebuild)" do
      stale = %({"schema_version": 999, "docs": []})
      AgentApropos::Index.load(stale).should be_nil
    end
  end

  describe "#covers?" do
    it "is true when every doc path and hash is unchanged" do
      conventions = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      AgentApropos::Index.build(conventions).covers?(conventions).should be_true
    end

    it "is false when a doc's content hash changed" do
      original = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      edited = [convention("docs/conventions/a.md", %(paths: ["lib/**"]))]
      AgentApropos::Index.build(original).covers?(edited).should be_false
    end

    it "is false when a doc was added or removed" do
      one = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      two = one + [convention("docs/conventions/b.md", %(paths: ["lib/**"]))]
      AgentApropos::Index.build(one).covers?(two).should be_false
    end
  end
end
