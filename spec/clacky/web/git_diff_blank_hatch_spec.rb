# frozen_string_literal: true

# In split view one side of a row is often empty. Those padding cells used to
# collapse to zero height (the parent uses align-items: flex-start), so a block
# of pure additions showed as a blank white column. They now stretch to the row
# height and carry a diagonal hatch, and the hatch period divides the row height
# so the strokes line up across consecutive rows.
RSpec.describe "Git panel split diff hatching" do
  let(:view) do
    File.read(File.expand_path("../../../lib/clacky/default_extensions/git/panels/git/view.js", __dir__))
  end

  let(:blank_rule) { view[/\.cg-half\.blank \{[^\n]*\}/] }

  it "stretches the empty half to the full row height" do
    expect(blank_rule).to include("align-self: stretch")
    expect(blank_rule).to include("min-height: 17.8px")
  end

  it "paints a diagonal hatch that stays in phase from row to row" do
    expect(blank_rule).to include("repeating-linear-gradient(135deg")

    period = blank_rule[/([\d.]+)px\); ?\}\z/, 1].to_f
    line_height = 11.5 * 1.55
    # 45° strokes advance vertically by period / sqrt(2) per repeat.
    expect(line_height / (period / Math.sqrt(2))).to be_within(0.02).of(4)
  end

  it "only touches the empty half, never the code cells" do
    expect(view).not_to match(/\.cg-half\.(add|del|old)[^{]*\{[^}]*repeating-linear-gradient/)
  end
end
