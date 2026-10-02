// Prose in this repo is never hard-wrapped: one paragraph per line, and the
// editor or renderer does the wrapping. Release notes are copied out of
// CHANGELOG.md, and GitHub soft-wraps prose, so a hard-wrapped source carries
// its line breaks into published text.
//
// markdownlint ships no rule for this (MD013 caps line length, which is the
// opposite), so it is a custom rule. It works on raw lines rather than tokens:
// the check is about the source's line breaks, which the token stream has
// already thrown away.

// A line that opens a block of its own, so following it is not a wrap.
const BLOCK_START =
  /^(#|[-*+][ \t]|\d+[.)][ \t]|>|\||\[[^\]]*\]:|```|~~~|<|={2,}$|-{3,}$|\*{3,}$|_{3,}$)/;

module.exports = {
  names: ["no-hard-wrap"],
  description: "Prose must not be hard-wrapped (one paragraph per line)",
  tags: ["whitespace", "prose"],
  parser: "none",
  function: function noHardWrap(params, onError) {
    const lines = params.lines;
    let inFence = false;
    let fenceMarker = "";

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Fenced code keeps every line it was written with.
      const fence = trimmed.match(/^(```+|~~~+)/);
      if (fence) {
        if (!inFence) {
          inFence = true;
          fenceMarker = fence[1][0];
        } else if (fence[1][0] === fenceMarker) {
          inFence = false;
        }
        continue;
      }
      if (inFence || !trimmed || i === 0) continue;

      const prev = lines[i - 1];
      if (!prev.trim()) continue;            // starts a block, not a continuation
      if (BLOCK_START.test(trimmed)) continue;
      if (prev.endsWith("  ")) continue;     // deliberate markdown hard break

      // Two consecutive deeply indented lines are an indented code block far
      // more often than a wrapped deep list item, and a false positive in CI
      // costs more than a miss.
      const indent = (s) => s.length - s.trimStart().length;
      if (indent(line) >= 4 && indent(prev) >= 4) continue;

      onError({
        lineNumber: i + 1,
        detail: "join this line with the one above it",
        context: trimmed.slice(0, 40),
      });
    }
  },
};
