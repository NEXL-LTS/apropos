require "../spec_helper"

# The warm hook path (index present) must stay well under the 50 ms budget
# (PRD §6). We assert the PRD's generous 4× ceiling (200 ms) to absorb
# runner noise, driving the logic in-process against a prebuilt 200-doc index
# so it measures match + render, not compilation or disk.
describe "Muninn::Hook performance" do
  it "resolves a warm PreToolUse well under the 4x latency budget" do
    files = {} of String => String
    conventions = [] of Muninn::Convention
    200.times do |i|
      path = "docs/conventions/rule_#{i}.md"
      doc = "---\npaths: [\"src/pkg_#{i}/**\"]\n---\n# Rule #{i}\n\nBody #{i}.\n"
      files["/repo/#{path}"] = doc
      conventions << Muninn::Convention.parse(path, doc)
    end
    files["/repo/.cache/muninn/index.json"] = Muninn::Index.build(conventions).to_document

    fs = InMemoryFS.new(files)
    payload = {session_id: "bench", tool_name: "Edit", cwd: "/repo",
               tool_input: {file_path: "src/pkg_137/x.cr"}}.to_json

    elapsed = Time.measure do
      Muninn::Hook.pre(IO::Memory.new(payload), IO::Memory.new, fs, Time.utc, "/repo")
    end

    elapsed.total_milliseconds.should be < 200
  end
end
