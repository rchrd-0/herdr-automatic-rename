// CONTRIBUTING.md bans the em dash in comments and docs, and the docs settle
// for " -- " or a comma instead. Nothing checked that until now, so a doc
// could break the rule for months without anyone noticing.
//
// Like no-hard-wrap, this works on raw lines rather than tokens. The check is
// about a single character, and fenced code is the one place it may appear:
// a grep command that searches for the character has to spell it.

module.exports = {
  names: ["no-em-dash"],
  description: "Prose uses -- or a comma, never an em dash",
  tags: ["prose"],
  parser: "none",
  function: function noEmDash(params, onError) {
    const lines = params.lines;
    let inFence = false;
    let fenceMarker = "";

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Fenced code keeps every character it was written with.
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
      if (inFence) continue;

      const column = line.indexOf("—");
      if (column === -1) continue;

      onError({
        lineNumber: i + 1,
        detail: "replace the em dash with -- or a comma",
        context: trimmed.slice(0, 40),
        range: [column + 1, 1],
      });
    }
  },
};
