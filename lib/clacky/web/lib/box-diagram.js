// ── BoxDiagram — cell-accurate repair for box-drawing diagrams ─────────────
//
// Models pad box rows by character count, so a row holding CJK comes out wider
// than the terminal-style cells it was aiming for. The TUI fixes this in Ruby
// (ui2/markdown_renderer.rb#align_box_diagrams); the browser needs its own copy
// because chat markdown is rendered here by marked.
//
// Two problems, both solved here:
//   1. Rows are padded by characters, not display cells. `align` re-pads every
//      row of a diagram to one shared cell width.
//   2. A CJK glyph is 1.66 ASCII advances in a browser monospace font, not 2,
//      so cell padding alone can never line up. `toHtml` wraps each wide glyph
//      in a span pinned to `2ch`, which restores the 1:2 ratio.
(function (global) {
  "use strict";

  var BOX_CHARS = "│┌┐└┘├┤┬┴┼";
  var BOX_CORNERS = "┌┐└┘";
  var BOX_OPEN = /^\s*┌.*┐\s*$/;
  var BOX_ROW_END = /[│┐┘┤]$/;
  // Frame followed by a floating label, e.g. `│ + │  ← tab bar`.
  var BOX_ANNOTATED = /^(.*│)(\s{2,}[^\s│┌┐└┘├┤┬┴┼][^│┌┐└┘├┤┬┴┼]*)$/;
  // East Asian Wide / Fullwidth: two cells, everywhere.
  var WIDE = /[\u1100-\u115F\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/;

  function charWidth(ch) {
    return WIDE.test(ch) ? 2 : 1;
  }

  function width(text) {
    var w = 0;
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        w += 2; // astral plane: CJK ext B and friends
        i++;
        continue;
      }
      w += charWidth(text.charAt(i));
    }
    return w;
  }

  function rstrip(text) {
    return text.replace(/\s+$/, "");
  }

  function countChars(text, chars) {
    var n = 0;
    for (var i = 0; i < text.length; i++) {
      if (chars.indexOf(text.charAt(i)) !== -1) n++;
    }
    return n;
  }

  function splitLabel(text) {
    var match = text.match(BOX_ANNOTATED);
    if (!match) return [text, null];
    return [match[1], match[2].replace(/^\s+|\s+$/g, "")];
  }

  function boxWidth(body) {
    var parts = splitLabel(rstrip(body));
    var text = rstrip(parts[0]);
    return BOX_ROW_END.test(text) ? width(text) : null;
  }

  // A frame holding free-standing boxes (no ┬/┼ anywhere) is gridded by those
  // boxes' own corners, e.g. `│  ┌──┐  ┌──┐  │`.
  function gridRow(text) {
    return /^\s*│/.test(text) && countChars(text, BOX_CORNERS) >= 2;
  }

  function barColumns(text, chars) {
    var cols = [];
    var offset = 0;
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (chars.indexOf(ch) !== -1) cols.push(offset);
      offset += charWidth(ch);
    }
    return cols;
  }

  // A border row is the grid; a frame drawn without one falls back to its first
  // content row, so the rest of the frame at least agrees with it.
  function targetBars(ref, bars) {
    if (!ref) return null;
    var inner = bars.slice(1, -1);
    var target = ref.length === inner.length ? ref : ref.slice(1, -1);
    if (!inner.length || target.length !== inner.length) return null;
    return [bars[0]].concat(target, [bars[bars.length - 1]]);
  }

  function fitCell(cell, cellWidth) {
    var text = cell.replace(/^\s+|\s+$/g, "");
    var pad = cellWidth - width(text);
    if (pad < 0) return null;
    if (pad === 0) return text;
    return " " + text + new Array(pad).join(" ");
  }

  // A cell that cannot fit its column leaves the row alone rather than
  // half-aligned; an exact fit closes the gap and keeps the bars lined up.
  function rebuildRow(text, bars) {
    var cells = text.split("│");
    if (cells.length !== bars.length + 1) return null;

    var fitted = [];
    for (var i = 0; i < bars.length - 1; i++) {
      var cellWidth = bars[i + 1] - bars[i] - 1;
      var cell = fitCell(cells[i + 1], cellWidth);
      if (cell === null) return null;
      fitted.push(cell);
    }

    var out = cells[0];
    for (var j = 0; j < fitted.length; j++) out += "│" + fitted[j];
    return out + "│" + cells[cells.length - 1];
  }

  function alignCells(rows) {
    var ref = null;
    return rows.map(function (row) {
      var text = rstrip(row);
      if (gridRow(text) || (/[┬┼]/.test(text) && /[┌├]/.test(text))) {
        ref = barColumns(text, BOX_CHARS);
        return row;
      }
      if (/^\s*[└┘]/.test(text)) {
        ref = null;
        return row;
      }
      if (/^\s*│/.test(text) && BOX_ROW_END.test(text)) {
        var bars = barColumns(text, "│");
        var target = targetBars(ref, bars);
        var rebuilt = target && rebuildRow(text, target);
        if (!ref && bars.length > 2) ref = bars;
        return rebuilt || row;
      }
      return row;
    });
  }

  // Frames grow to the widest row instead of cutting content.
  function alignBlock(rows) {
    var aligned = alignCells(rows);
    var target = 0;
    aligned.forEach(function (row) {
      var w = boxWidth(row);
      if (w !== null && w > target) target = w;
    });

    return aligned.map(function (row) {
      var parts = splitLabel(rstrip(row));
      var body = parts[0];
      var label = parts[1];
      // A connector carrying a label is not a frame row; padding it would shove
      // the label past the frame it annotates.
      var resized = label && countChars(body, BOX_CHARS) < 2 ? body : resize(body, target);
      return label ? resized + "  " + label : resized;
    });
  }

  function resize(body, target) {
    var text = rstrip(body);
    if (!BOX_ROW_END.test(text)) return body;

    var diff = target - width(text);
    if (diff <= 0) return text;

    var filler = /^\s*[┌└├]/.test(text) ? "─" : " ";
    var pad = new Array(diff + 1).join(filler);
    return text.slice(0, -1) + pad + text.charAt(text.length - 1);
  }

  function hasFrame(text) {
    if (!text || text.indexOf("┌") === -1) return false;
    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
      if (BOX_OPEN.test(lines[i])) return true;
    }
    return false;
  }

  function align(content) {
    if (!hasFrame(content)) return content;

    var lines = content.split("\n");
    var out = [];
    var i = 0;
    while (i < lines.length) {
      if (BOX_OPEN.test(lines[i])) {
        var stop = i;
        while (stop + 1 < lines.length && blockLine(lines[stop + 1])) stop++;
        out = out.concat(alignBlock(lines.slice(i, stop + 1)));
        i = stop + 1;
        continue;
      }
      out.push(lines[i]);
      i++;
    }
    return out.join("\n");
  }

  function blockLine(line) {
    var text = rstrip(line);
    if (!text.replace(/\s/g, "")) return false;
    return BOX_ROW_END.test(text) || /^\s*│/.test(text);
  }

  // Every wide glyph is pinned to 2ch, putting the browser font back on the 1:2
  // grid the diagram was drawn for.
  function toHtml(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      var code = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        out += '<span class="bd-c">' + text.substr(i, 2) + "</span>";
        i++;
        continue;
      }
      if (ch === "&") out += "&amp;";
      else if (ch === "<") out += "&lt;";
      else if (ch === ">") out += "&gt;";
      else if (WIDE.test(ch)) out += '<span class="bd-c">' + ch + "</span>";
      else out += ch;
    }
    return out;
  }

  global.BoxDiagram = {
    align: align,
    hasFrame: hasFrame,
    toHtml: toHtml,
    width: width
  };
})(window);
