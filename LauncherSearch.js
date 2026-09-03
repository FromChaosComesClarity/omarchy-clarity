// Scoring and ranking for the launcher overlay.
//
// ⚠️ `score` is the Manager's own _PAL_ACTIONS scorer, character for character. The
// Ctrl+K palette inside the app and this overlay outside it are two doors onto the same
// library, and typing "kcd" should not rank differently depending on which one is open ,
// so when one changes, the other changes with it. That shared behaviour is why the
// palette was built first.
//
// Kept as plain functions with no QML imports so it can be run under node for testing.

// Subsequence match, the same rule a fuzzy launcher uses: every character of the query
// must appear in order. Scoring prefers a prefix hit, then a word-start hit, then
// anything, so "kcd" finds "Kingdom Come: Deliverance" but an exact prefix still wins
// the top slot.
function score(hay, q) {
  var h = String(hay || "").toLowerCase()
  if (!q) return 1
  var idx = h.indexOf(q)
  if (idx === 0) return 1000
  if (idx > 0) return 700 - Math.min(idx, 200) + (/[\s:._-]/.test(h[idx - 1]) ? 150 : 0)
  var i = 0, s = 300, last = -1
  // Array.from, not q[c]: the app iterates the query with for…of, which walks code
  // points. Indexing walks code units, and the two disagree the moment a query holds
  // anything outside the BMP.
  var chars = Array.from(q)
  for (var c = 0; c < chars.length; c++) {
    var at = h.indexOf(chars[c], i)
    if (at === -1) return 0
    if (last >= 0 && at === last + 1) s += 12   // reward contiguity
    last = at; i = at + 1
  }
  return s
}

function normalize(query) {
  return String(query || "").trim().toLowerCase()
}

// With nothing typed, this is a launcher and not a menu: what you reach for is what you
// played last. Recently played first, then the rest of what is installed, then the
// actions, then everything you own but have not installed. Once something IS typed,
// ranking is the palette's scorer and the ordering below stops applying.
//
// ⚠️ Tier first, timestamp second, never a timestamp folded into a score. LastPlayed is
// written in milliseconds, and an earlier version of this squeezed it into a number that
// saturated: all 127 played games came out equal and the recency ordering was silently
// alphabetical. Comparing the two fields separately cannot round anything away.
function idleTier(row) {
  if (row.kind === "game" && row.installed && row.lastPlayed > 0) return 3
  if (row.kind === "game" && row.installed) return 2
  if (row.kind === "action") return 1
  return 0
}

function idleCompare(a, b) {
  var ta = idleTier(a), tb = idleTier(b)
  if (ta !== tb) return tb - ta
  if (ta === 3 && a.lastPlayed !== b.lastPlayed) return b.lastPlayed - a.lastPlayed
  return a.name.localeCompare(b.name)
}

/*
 * index , { games: [{id,name,store,installed,lastPlayed}], actions: [{id,name}] }
 * query , what the user typed
 * limit , how many rows to hand back
 *
 * Rows come back ready to render: { kind, id, name, badge, installed }.
 */
function search(index, query, limit) {
  var q = normalize(query)
  var games = (index && index.games) || []
  var actions = (index && index.actions) || []
  var max = limit === undefined || limit === null ? 60 : Number(limit)
  var rows = []
  var i

  for (i = 0; i < actions.length; i++) {
    var s = score(actions[i].name, q)
    if (!s) continue
    // The palette's +40: an action you named exactly outranks a game that merely
    // contains the word, because you typed the name of a thing you meant to do.
    rows.push({ kind: "action", id: actions[i].id, name: actions[i].name,
                badge: "action", installed: false, lastPlayed: 0, score: s + 40,
                cover: "", blurb: "", genre: "", year: "", store: "", playtime: 0 })
  }

  for (i = 0; i < games.length; i++) {
    var g = games[i]
    var gs = score(g.name, q)
    if (!gs) continue
    // ⚠️ The one place this deliberately differs from the in-app palette: an installed
    // game outranks an uninstalled one that scored the same. In the app both are one
    // click from something useful; out here, Enter on the installed one starts playing.
    // The preview pane's fields ride along on the row rather than being looked up again by
    // id: the list is rebuilt on every keystroke and a second pass over 877 games to find
    // the one under the cursor would be work done 877 times to use once.
    rows.push({ kind: "game", id: g.id, name: g.name,
                badge: g.installed ? "play" : "install",
                installed: !!g.installed, lastPlayed: g.lastPlayed || 0,
                score: gs + (g.installed ? 20 : 0),
                cover: g.cover || "", blurb: g.blurb || "", genre: g.genre || "",
                year: g.year || "", store: g.store || "", playtime: g.playtime || 0 })
  }

  if (!q) {
    rows.sort(idleCompare)
  } else {
    rows.sort(function (a, b) {
      return b.score - a.score || a.name.localeCompare(b.name)
    })
  }

  return { total: rows.length, rows: rows.slice(0, Math.max(0, max)) }
}

function parseIndex(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || data.ok !== true) return { ok: false, error: (data && data.error) || "no index", games: [], actions: [], exec: "", version: "" }
    return { ok: true, error: "", exec: String(data.exec || ""),
             version: String(data.version || ""),
             games: Array.isArray(data.games) ? data.games : [],
             actions: Array.isArray(data.actions) ? data.actions : [] }
  } catch (e) {
    return { ok: false, error: "unreadable index", games: [], actions: [], exec: "", version: "" }
  }
}

if (typeof module !== "undefined") {
  module.exports = { score: score, search: search, parseIndex: parseIndex, normalize: normalize }
}
