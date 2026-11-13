# frozen_string_literal: true

RSpec.describe "Settings section headings and memory rows" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:markup)  { File.read(File.join(web_dir, "index.html")) }
  let(:i18n)    { File.read(File.join(web_dir, "i18n.js")) }
  let(:styles)  { File.read(File.join(web_dir, "app.css")) }

  describe "section heading icons" do
    it "gives every section title a heading wrapper and an icon" do
      titles   = markup.scan('class="settings-section-title"').size
      headings = markup.scan('class="settings-section-heading"').size
      icons    = markup.scan('class="settings-section-icon"').size

      expect(titles).to be > 0
      expect(headings).to eq(titles)
      expect(icons).to eq(titles)
    end

    it "puts the icon immediately inside the heading wrapper" do
      pairs = markup.scan(/class="settings-section-heading">\s*<svg class="settings-section-icon"/).size
      expect(pairs).to eq(markup.scan('class="settings-section-heading"').size)
    end

    # I18n.applyAll() assigns textContent, which wipes any child node. The SVG
    # therefore has to sit next to the [data-i18n] span, never inside it.
    it "keeps the icon out of the i18n text node" do
      expect(markup).not_to match(/data-i18n="[^"]*"[^>]*>[^<]*<svg/)
    end

    it "keeps every localized heading label as a plain text node" do
      headings = markup.scan(%r{class="settings-section-heading">\s*<svg.*?</svg>\s*<span data-i18n="([^"]+)">})
      expect(headings.size).to eq(markup.scan('class="settings-section-heading"').size)
      headings.flatten.each do |key|
        expect(i18n.scan(%("#{key}":)).size).to eq(2), "#{key} must exist in both locales"
      end
    end

    it "styles the icon at a fixed size in the heading's own colour" do
      block = styles[/\.settings-section-icon\s*\{[^}]*\}/]
      expect(block).not_to be_nil
      expect(block).to include("width: 1rem", "height: 1rem", "flex-shrink: 0")
      expect(block).to include("color: currentColor")
    end

    # Feather glyphs fill anywhere from 14 to 22 units of the 24 grid, so the
    # narrow ones get scaled up and the wide ones down to a common 20-unit
    # optical box. Scaling would also fatten the stroke, hence the compensation.
    describe "optical size normalisation" do
      let(:scaled) { markup.scan(/<g transform="translate\(([-\d.]+) ([-\d.]+)\) scale\(([\d.]+)\)" stroke-width="([\d.]+)">/) }

      it "compensates the stroke width for every scaled glyph" do
        expect(scaled).not_to be_empty

        scaled.each do |_tx, _ty, scale, stroke|
          expect(scale.to_f * stroke.to_f).to be_within(0.02).of(2.5)
        end
      end

      it "keeps the scaling within a sane range" do
        scaled.each do |_tx, _ty, scale, _stroke|
          expect(scale.to_f).to be_between(0.85, 1.30)
        end
      end

      it "draws every glyph with one stroke weight" do
        roots = markup.scan(/<svg class="settings-section-icon"[^>]*stroke-width="([\d.]+)"/).flatten.uniq
        expect(roots).to eq(["2.5"])
      end

      it "leaves exactly the glyphs that already fill the box unscaled" do
        plain = markup.scan(%r{class="settings-section-heading">\s*<svg class="settings-section-icon"[^>]*>(?!<g transform)}).size
        expect(plain).to eq(6)
      end
    end
  end

  # The advisor panel builds its settings body in JS, so its heading has to be
  # checked against view.js rather than index.html.
  describe "advisor panel heading" do
    let(:advisor_js) do
      File.read(File.expand_path("../../../lib/clacky/default_extensions/advisor/panels/advisor/view.js", __dir__))
    end

    it "reuses the shared heading wrapper and icon" do
      expect(advisor_js).to include('heading.className = "settings-section-heading"')
      expect(advisor_js).to include('class="settings-section-icon"')
      expect(advisor_js).to include('stroke="currentColor" stroke-width="2.5"')
    end

    # .settings-section-title > span carries the bold weight; a bare text node
    # on the title itself would render a step lighter than every other section.
    it "puts the panel title in a span so it picks up the bold weight" do
      expect(advisor_js).to match(/headingLabel\.textContent = t\("advisor\.settingsTitle"/)
      expect(advisor_js).to match(/heading\.appendChild\(headingLabel\)/)
      expect(advisor_js).not_to match(/title\.textContent = t\("advisor\.settingsTitle"/)
    end
  end

  describe "memory toggle rows" do
    let(:rows) { markup.scan(%r{<div class="settings-personalize">\s*<div class="settings-personalize-text">.*?</div>}m) }

    it "labels each toggle with a title above the description" do
      expect(markup.scan('class="settings-personalize-title"').size).to eq(2)
      expect(rows.size).to eq(2)

      rows.each do |row|
        title_at = row.index("settings-personalize-title")
        desc_at  = row.index("settings-personalize-desc")
        expect(title_at).to be < desc_at
      end
    end

    it "ships titles for both toggles in both locales" do
      %w[settings.memory.update.title settings.memory.inject.title].each do |key|
        expect(i18n.scan(%("#{key}":)).size).to eq(2), "#{key} must exist in both locales"
      end
    end

    it "splits the auto-recall cost note out of the description" do
      desc = i18n[/"settings\.memory\.inject\.desc":\s*"([^"]+)"/, 1]
      cost = i18n[/"settings\.memory\.inject\.cost":\s*"([^"]+)"/, 1]

      expect(desc).not_to include("model call", "小模型调用")
      expect(cost).to include("model call")
      expect(i18n.scan(/"settings\.memory\.inject\.cost":/).size).to eq(2)
    end

    it "renders the cost note as a dimmer line below the description" do
      hint_at = rows.last.index("settings-personalize-hint")
      desc_at = rows.last.index("settings-personalize-desc")
      expect(hint_at).to be > desc_at

      block = styles[/\.settings-personalize-hint\s*\{[^}]*\}/]
      expect(block).to include("color: var(--color-text-tertiary)")
    end

    it "sets the title a step above the description" do
      title_size = styles[/\.settings-personalize-title\s*\{[^}]*font-size:\s*([\d.]+)rem/m, 1].to_f
      desc_size  = styles[/\.settings-personalize-desc\s*\{[^}]*font-size:\s*([\d.]+)rem/m, 1].to_f

      expect(title_size).to be > desc_size
    end

    it "keeps the toggles wired to their switches" do
      expect(markup).to include('id="settings-memory-update-toggle"', 'id="settings-memory-inject-toggle"')
    end
  end
end
