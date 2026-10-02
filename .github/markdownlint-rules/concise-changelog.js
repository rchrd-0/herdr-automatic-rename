// Changelog entries are summaries, not essays. The release workflow copies
// each version's section into its GitHub Release verbatim, so an entry that
// explains the whole bug ships as a wall of text. The reasoning belongs in the
// commit and docs/ARCHITECTURE.md.
//
// Every bullet and paragraph under a version heading in CHANGELOG.md gets at
// most MAX_SENTENCES sentences and MAX_CHARS visible characters, and must be
// a single line with no indented continuation or nested list below it.

const MAX_SENTENCES = 3;
const MAX_CHARS = 400;

// What a reader sees: code spans and link targets carry periods that do not
// end sentences, and a URL is not prose length.
function visible(text) {
  return text
    .replace(/`[^`]*`/g, "x")
    .replace(/\]\([^)]*\)/g, "]")
    .replace(/^([-*+]|\d+[.)])[ \t]+/, "");
}

function sentences(text) {
  const ends = text.match(/[.!?]["')\]]*(?=\s|$)/g);
  return ends ? ends.length : 1;
}

module.exports = {
  names: ["concise-changelog"],
  description: "Changelog entries are one line of at most three sentences",
  tags: ["prose"],
  parser: "none",
  function: function conciseChangelog(params, onError) {
    if (!/(^|[\\/])CHANGELOG\.md$/.test(params.name)) return;
    const lines = params.lines;
    let inRelease = false;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();
      if (/^## /.test(line)) {
        inRelease = /^## \[/.test(line);
        continue;
      }
      if (!inRelease || !trimmed || /^#/.test(trimmed)) continue;
      if (/^\[[^\]]*\]:/.test(trimmed)) continue; // link reference

      if (/^\s/.test(line)) {
        onError({
          lineNumber: i + 1,
          detail: "fold this into the entry above as one line, or cut it",
          context: trimmed.slice(0, 40),
        });
        continue;
      }

      const text = visible(trimmed);
      const n = sentences(text);
      if (n > MAX_SENTENCES || text.length > MAX_CHARS) {
        onError({
          lineNumber: i + 1,
          detail: `${n} sentences, ${text.length} chars (max ${MAX_SENTENCES} and ${MAX_CHARS})`,
          context: trimmed.slice(0, 40),
        });
      }
    }
  },
};
