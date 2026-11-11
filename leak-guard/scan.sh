#!/usr/bin/env bash
# Check what git is about to publish for leaks: feed it to match.pl.
# Works in the current git repository. Exit 0 clean, 1 found, 2 error.
#
#   scan.sh [--redact] [--patterns-only] <mode>
#     --staged                      the index against HEAD (pre-commit)
#     --message <file>              a commit message file, every line
#     --range <a>..<b>              patches and messages of the commits in a range
#     --commits-not-on <remote> <ref>  commits of <ref> no <remote>/* branch has
#     --tag <name> [--remote <r>]   the tag message and its commits no remote has
#                                   (no <r>/* branch has, when --remote is given);
#                                   <name> may be a full object id
#     --file <path>...              whole files, path relative to the repo root
#     --tree                        every tracked text file as it is now
#     --history                     every commit of every ref, every tag message
#     --validate                    check the stoplist itself
#   --redact         print where and which rule, never the matched text
#   --patterns-only  public patterns alone, no stoplist needed
#
# Stoplist: $LEAK_GUARD_STOPLIST, else ../../spine-notes/leak-guard/stoplist.txt
# next to this script. None found is an error (exit 2) unless --patterns-only.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# die MESSAGE [VALUE]: under --redact a value from the command line (a tag
# name, a path, a range) may itself be the leak, so it is left out.
die() {
  if [ -n "${2:-}" ] && [ "$REDACT" -eq 0 ]; then echo "error: $1 '$2'" >&2; else echo "error: $1" >&2; fi
  exit 2
}
usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --redact is known before any error is reported. Arguments after --file are
# paths, not flags.
REDACT=0
for a in "$@"; do
  case "$a" in --file) break ;; --redact) REDACT=1 ;; esac
done
PONLY=0
MODE=""
A1=""
A2=""
REMOTE=""
TAGREV=""
FILES=()
set_mode() { [ -z "$MODE" ] || die "one mode at a time ($MODE and $1)"; MODE="$1"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --redact) REDACT=1; shift ;;
    --patterns-only) PONLY=1; shift ;;
    --staged|--tree|--history|--validate) set_mode "$1"; shift ;;
    --remote)
      [ $# -ge 2 ] || die "$1 needs an argument"
      REMOTE="$2"; shift 2 ;;
    --message|--range|--tag)
      [ $# -ge 2 ] || die "$1 needs an argument"
      set_mode "$1"; A1="$2"; shift 2 ;;
    --commits-not-on)
      [ $# -ge 3 ] || die "$1 needs <remote> <ref>"
      set_mode "$1"; A1="$2"; A2="$3"; shift 3 ;;
    --file)
      # Everything after --file is a path, so a file named like a flag works.
      set_mode "$1"; shift
      [ $# -gt 0 ] || die "--file needs at least one path"
      FILES=("$@"); shift $# ;;
    *) die "unrecognized argument" "$1" ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }
[ -z "$REMOTE" ] || [ "$MODE" = --tag ] || die "--remote goes with --tag only"

# Paths with spaces or Cyrillic must reach the output and the allow check as
# they are in the repo, not as git's octal-escaped quoting.
g() { git -c core.quotePath=false -c diff.relative=false -c log.showRoot=true "$@"; }

TOP="$(g rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"

SL_DEFAULT="$HERE/../../spine-notes/leak-guard/stoplist.txt"
SL="${LEAK_GUARD_STOPLIST:-$SL_DEFAULT}"
if [ "$PONLY" -eq 0 ] || [ "$MODE" = --validate ]; then
  [ -f "$SL" ] || die "no stoplist at $SL (set LEAK_GUARD_STOPLIST, or put it at $SL_DEFAULT; --patterns-only checks the public patterns alone)"
fi
if [ "$MODE" = --validate ]; then
  exec perl "$HERE/match.pl" --validate --stoplist "$SL"
fi

# The repo name an allow record names: a worktree or a clone may sit in a
# folder with any name, so origin's URL wins over the folder.
repo_name() {
  local url n
  url="$(g config --get remote.origin.url || true)"
  if [ -n "$url" ]; then
    n="${url%/}"; n="${n##*/}"; n="${n##*:}"; n="${n%.git}"
  else
    n="$(basename -- "$TOP")"
  fi
  printf '%s\n' "$n"
}
REPO="$(repo_name)"

# Stream records are "<loc>TAB<path>TAB<text>"; a TAB inside a field would
# shift the columns, so it becomes a space. awk runs in the C locale: bytes
# pass through untouched whatever the file's encoding.
EMIT='function emit(loc, p, t) { gsub(/\t/, " ", loc); gsub(/\t/, " ", p); gsub(/\t/, " ", t); printf "%s\t%s\t%s\n", loc, p, t }'

# Patches, one git call per mode. "\001<sha>" starts a commit (none for
# --staged). Only lines a hunk adds are records; a new file also gives a
# record for its name. Hunk line counts decide where a hunk ends, so an added
# line that looks like a header ("+++ b/x") is still read as content.
PATCH_AWK="$EMIT"'
function unq(s,   o, i, c, n, v) {
  if (substr(s, 1, 1) != "\"") return s
  s = substr(s, 2, length(s) - 2); o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c != "\\") { o = o c; continue }
    c = substr(s, ++i, 1)
    if (c ~ /[0-7]/) {
      v = 0
      for (n = 0; n < 3 && substr(s, i, 1) ~ /[0-7]/; n++) { v = v * 8 + substr(s, i, 1); i++ }
      i--; o = o sprintf("%c", v)
    } else if (c == "t" || c == "n") o = o " "
    else o = o c
  }
  return o
}
function count(r,   k) { k = index(r, ","); return k ? substr(r, k + 1) + 0 : 1 }
function start(r,   k) { k = index(r, ","); return (k ? substr(r, 2, k - 2) : substr(r, 2)) + 0 }
function at(n) { return staged ? path ":" n : "commit " sha " " path ":" n }
substr($0, 1, 1) == "\001" { sha = substr($0, 2); inh = 0; next }
inh {
  c = substr($0, 1, 1)
  if (c == "+") { emit(at(nl), path, substr($0, 2)); nl++; nn-- }
  else if (c == "-") no--
  else if (c == " ") { nl++; nn--; no-- }
  if (no <= 0 && nn <= 0) inh = 0
  next
}
/^diff --git / {
  # Without renames both sides name the same path: "a/P b/P" or "\"a/P\" \"b/P\"".
  r = substr($0, 12)
  if (substr(r, 1, 1) == "\"") path = unq("\"" substr(r, 4, (length(r) - 9) / 2) "\"")
  else path = substr(r, 3, (length(r) - 5) / 2)
  next
}
/^new file mode / { emit(staged ? path " (path)" : "commit " sha " " path, path, path); next }
/^@@ / {
  split($0, h, " ")
  no = count(h[2]); nn = count(h[3]); nl = start(h[3])
  inh = (no > 0 || nn > 0)
  next
}'

MSG_AWK="$EMIT"'
substr($0, 1, 1) == "\001" { sha = substr($0, 2); n = 0; next }
{ n++; emit("commit " sha " message:" n, "", $0) }'

DIFF_OPTS=(-p --no-color --no-ext-diff --no-textconv --no-renames --submodule=short -U0 --src-prefix=a/ --dst-prefix=b/)

# Messages of every commit the revisions select, merges included.
messages() {
  g log --format='%x01%h%n%B' "$@" | LC_ALL=C awk "$MSG_AWK" || exit 2
}
# Patches of the same commits; a merge adds nothing its parents did not, so
# its message is all that is read from it.
patches() {
  g log --no-merges --format='%x01%h' "${DIFF_OPTS[@]}" "$@" | LC_ALL=C awk -v staged=0 "$PATCH_AWK" || exit 2
}
commits() { messages "$@"; patches "$@"; }

# The message of an annotated tag object: what follows the header's blank line.
tag_message() {  # label object
  g cat-file tag "$2" | sed '1,/^$/d' \
    | LC_ALL=C awk -v t="$1" "$EMIT"' { emit("tag " t " message:" NR, "", $0) }' || exit 2
}

stream_staged() {
  g diff --cached "${DIFF_OPTS[@]}" | LC_ALL=C awk -v staged=1 "$PATCH_AWK" || exit 2
}

# Every line, comment lines and the scissors line of `commit -v` with all that
# follows it included: `-m` and `-F` keep that text in the commit, so it is
# published.
stream_message() {
  LC_ALL=C awk "$EMIT"' { emit("message:" NR, "", $0) }' "$A1" || exit 2
}

# Commits the tag adds: those no remote branch has, or, when the push goes to
# one remote, those that remote's branches lack.
stream_tag() {
  local rem=--remotes
  [ -z "$REMOTE" ] || rem="--remotes=$REMOTE"
  if [ "$(g cat-file -t "$TAGREV")" = tag ]; then tag_message "$A1" "$TAGREV"; fi
  commits "$TAGREV" --not "$rem"
}

# A path outside this repo is reported as given.
stream_files() {
  local f d b rel
  for f in "${FILES[@]}"; do
    d="$(dirname -- "$f")"; b="$(basename -- "$f")"
    rel="$f"
    if [ "$(cd -- "$d" && g rev-parse --show-toplevel 2>/dev/null)" = "$TOP" ]; then
      rel="$(cd -- "$d" && g rev-parse --show-prefix)$b"
    fi
    # Binary the way git decides it: a NUL in the first 8000 bytes. Text in a
    # legacy encoding is still text and still checked.
    if [ "$(head -c 8000 -- "$f" | LC_ALL=C tr -d -c '\000' | wc -c)" -gt 0 ]; then continue; fi
    LC_ALL=C awk -v p="$rel" "$EMIT"' { emit(p ":" FNR, p, $0) }' "$f" || exit 2
  done
}

# File names of every tracked file, then their text. Both git calls give
# NUL-separated verbatim paths; perl splits on NUL, so a TAB or a colon in a
# path cannot shift the fields.
stream_tree() {
  g -C "$TOP" ls-files -z \
    | perl -0 -ne 'chomp; s/[\t\n]/ /g; print "$_ (path)\t$_\t$_\n"' || exit 2
  { g -C "$TOP" -c grep.column=false -c grep.fullName=true grep -I -n -z --no-color -e '' -- . || [ $? -eq 1 ]; } \
    | perl -ne 'chomp; my ($p, $n, $t) = split /\0/, $_, 3; next unless defined $t;
        s/\t/ /g for $p, $t; print "$p:$n\t$p\t$t\n"' || exit 2
}

stream_history() {
  local t
  commits --all
  g for-each-ref --format='%(objecttype) %(refname:strip=2)' refs/tags | while read -r kind t; do
    if [ "$kind" = tag ]; then tag_message "$t" "refs/tags/$t"; fi
  done || exit 2
}

# Arguments are checked before the stream starts, so a typo is an error and
# not a clean pass over nothing.
case "$MODE" in
  --message) [ -f "$A1" ] || die "no message file" "$A1" ;;
  --range) case "$A1" in *..*) ;; *) die "--range wants <a>..<b>" ;; esac
    g rev-parse --quiet --verify "${A1%%..*}^{commit}" >/dev/null && g rev-parse --quiet --verify "${A1##*..}^{commit}" >/dev/null \
      || die "--range: unknown revision in" "$A1" ;;
  --commits-not-on) g rev-parse --quiet --verify "$A2^{commit}" >/dev/null || die "--commits-not-on: unknown ref" "$A2" ;;
  --tag)
    # A name, or the full object id of what a push puts under a tag name.
    TAGREV="refs/tags/$A1"
    if ! g rev-parse --quiet --verify "$TAGREV" >/dev/null; then
      case "$A1" in
        *[!0-9a-f]*) die "--tag: no tag" "$A1" ;;
      esac
      case "${#A1}" in 40|64) ;; *) die "--tag: no tag" "$A1" ;; esac
      TAGREV="$A1"
      g rev-parse --quiet --verify "$TAGREV^{object}" >/dev/null || die "--tag: no tag" "$A1"
    fi
    # A push can put a tree or a blob under a tag name, and a tag can point at
    # one: there is nothing to read in it, which must not pass as clean.
    g rev-parse --quiet --verify "$TAGREV^{commit}" >/dev/null 2>&1 || die "--tag: not a commit, nor a tag of one" "$A1" ;;
  --file) for f in "${FILES[@]}"; do [ -f "$f" ] || die "--file: no file" "$f"; done ;;
esac

stream() {
  case "$MODE" in
    --staged) stream_staged ;;
    --message) stream_message ;;
    --range) commits "$A1" ;;
    --commits-not-on) commits "$A2" --not --remotes="$A1" ;;
    --tag) stream_tag ;;
    --file) stream_files ;;
    --tree) stream_tree ;;
    --history) stream_history ;;
  esac
}

MARGS=(--patterns "$HERE/patterns.txt" --repo "$REPO")
[ "$PONLY" -eq 1 ] || MARGS+=(--stoplist "$SL")
[ "$REDACT" -eq 0 ] || MARGS+=(--redact)

# Under --redact git's own errors stay out of the output: they can quote a
# revision or a path.
set +e
if [ "$REDACT" -eq 1 ]; then
  stream 2>/dev/null | perl "$HERE/match.pl" "${MARGS[@]}"
  st=("${PIPESTATUS[@]}")
else
  stream | perl "$HERE/match.pl" "${MARGS[@]}"
  st=("${PIPESTATUS[@]}")
fi
set -e
[ "${st[1]}" -ne 2 ] || exit 2
[ "${st[0]}" -eq 0 ] || die "git failed ($MODE)"
if [ "${st[1]}" -eq 1 ] && [ "$REDACT" -eq 0 ]; then
  echo "hint: replace the data with a placeholder, or add 'allow <value> $REPO:<path>' to the stoplist and run sync-leak-secret.sh" >&2
fi
exit "${st[1]}"
