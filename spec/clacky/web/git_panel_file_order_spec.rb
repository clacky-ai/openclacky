# frozen_string_literal: true

# The diff stream used to follow whatever order git printed the paths in
# (byte order), while the file tree draws every directory's children before its
# files and collates names with the locale. On the same change set that put
# `README.md` first on the right and `docs/` first on the left, so the two panes
# could not be matched row by row. The stream now flattens the tree in walk
# order, which keeps one definition of "sorted" for both panes.
RSpec.describe "Git panel file order" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/default_extensions/git/panels/git/view.js", __dir__))
  end

  let(:sort_files) do
    from = view.index("function sortFiles(files)")
    expect(from).not_to be_nil
    view[from...view.index("function matchesFilter(file)", from)]
  end

  it "flattens the file tree in walk order, directories before files" do
    expect(sort_files).to include("visit(buildTree(files))")
    expect(sort_files.index("Array.from(node.dirs.values())")).to be < sort_files.index("node.files")
  end

  it "collates directories and files exactly like the tree does" do
    expect(view.scan("a.name.localeCompare(b.name)").size).to be >= 2
    expect(view.scan("a.path.localeCompare(b.path)").size).to be >= 2
  end

  it "takes the refresh payload through the same order instead of raw git output" do
    expect(view).to include("state.files = sortFiles(data.files || []);")
    expect(view).not_to include("state.files = data.files || [];")
  end
end
