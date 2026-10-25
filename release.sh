#!/bin/zsh
# One-command release. Usage: ./release.sh <patch|minor|major|X.Y.Z> [--dry-run]
# The rules are in RELEASING.md. --dry-run runs every check and changes nothing.
set -euo pipefail
cd "$(dirname "$0")"

ARG="${1:?usage: ./release.sh <patch|minor|major|X.Y.Z> [--dry-run]}"
DRY=0; [[ "${2:-}" == "--dry-run" ]] && DRY=1
fail() { echo "Refusing to release: $1"; exit 1; }

# 1. Where we are
CUR="$(tr -d '[:space:]' < VERSION)"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "not on main."
[[ -z "$(git status --porcelain)" ]] || fail "working tree not clean. Commit or stash first."
git fetch -q origin main || fail "cannot reach origin."
[[ "$(git rev-list --count HEAD..origin/main)" == "0" ]] || fail "behind origin/main. Pull first."

# 2. The new version
IFS=. read -r MA MI PA <<< "$CUR"
case "$ARG" in
  patch) V="$MA.$MI.$((PA+1))"; BUMP=patch ;;
  minor) V="$MA.$((MI+1)).0"; BUMP=minor ;;
  major) V="$((MA+1)).0.0"; BUMP=major ;;
  *) [[ "$ARG" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "'$ARG' is not patch, minor, major or X.Y.Z."
     V="$ARG"
     IFS=. read -r NA NI NP <<< "$V"
     if (( NA > MA )); then BUMP=major; elif (( NI > MI )); then BUMP=minor; else BUMP=patch; fi
     (( NA > MA || (NA == MA && NI > MI) || (NA == MA && NI == MI && NP > PA) )) || fail "$V is not higher than $CUR." ;;
esac
git rev-parse "v$V" >/dev/null 2>&1 && fail "tag v$V already exists."

# 3. The changelog must say what changed, and the bump must match it
NOTES="$(python3 - <<'PY'
import re, sys
t = open("CHANGELOG.md").read()
m = re.search(r"## \[Unreleased\]\n(.*?)(?=\n## \[|\Z)", t, re.S)
body = m.group(1).strip() if m else ""
print(body)
PY
)"
echo "$NOTES" | grep -q '^- ' || fail "[Unreleased] in CHANGELOG.md has no entries. Add a line for each change."
if echo "$NOTES" | grep -q '^### Breaking' && [[ "$BUMP" != major ]]; then fail "the changelog lists breaking changes, so this must be a major release."; fi
if echo "$NOTES" | grep -q '^### Added' && [[ "$BUMP" == patch ]]; then fail "the changelog lists new features, so this must be at least a minor release."; fi

# 4. Quality gate
./scripts/check.sh

echo "Ready: $CUR -> $V ($BUMP)"
echo "$NOTES"
(( DRY )) && { echo "Dry run, nothing changed."; exit 0; }

# 5. Release
echo "$V" > VERSION
python3 - "$V" <<'PY'
import re, sys, datetime
v = sys.argv[1]
t = open("CHANGELOG.md").read()
t = t.replace("## [Unreleased]\n", "## [Unreleased]\n\n## [%s] - %s\n" % (v, datetime.date.today().isoformat()), 1)
open("CHANGELOG.md", "w").write(t)
PY
printf '%s\n' "$NOTES" > build-notes.md
git add VERSION CHANGELOG.md
git commit -qm "Release $V"
./build.sh release
git tag "v$V"
git push -q origin HEAD "v$V"
gh release create "v$V" "build/Switchboard-$V.zip" --title "Switchboard $V" --notes-file build-notes.md
rm -f build-notes.md

# Update the Homebrew cask (destucr/homebrew-tap) with the new version + checksum
SHA="$(shasum -a 256 "build/Switchboard-$V.zip" | cut -d' ' -f1)"
CASK="Casks/switchboard.rb"
CUR="$(gh api "repos/destucr/homebrew-tap/contents/$CASK")"
FILE_SHA="$(printf '%s' "$CUR" | jq -r .sha)"
OLD="$(printf '%s' "$CUR" | jq -r .content | base64 -d)"
HAS_BIN="$(printf '%s\n' "$OLD" | grep -c '^  binary "' || true)"
# One binary line: add it if the cask has none, and drop any repeats.
NEW="$(printf '%s\n' "$OLD" | awk -v has="$HAS_BIN" '/^  binary "/ { if (seen++) next } {print} /^  app "Switchboard.app"/ && has == 0 {print "  binary \"#{appdir}/Switchboard.app/Contents/MacOS/Switchboard\", target: \"switchboard\""}' | sed -E "s/^(  version \").*(\")/\1$V\2/; s/^(  sha256 \").*(\")/\1$SHA\2/")"
gh api -X PUT "repos/destucr/homebrew-tap/contents/$CASK" -f message="switchboard $V" \
  -f content="$(printf '%s\n' "$NEW" | base64)" -f sha="$FILE_SHA" -f branch=main --jq .commit.html_url
echo "Released v$V"

# 6. Check that what we published is what people will get
gh release view "v$V" --json assets --jq '.assets[].name' | grep -q "Switchboard-$V.zip" || { echo "WARNING: release asset missing."; exit 1; }
TAPV="$(gh api "repos/destucr/homebrew-tap/contents/$CASK" --jq .content | base64 -d | sed -n 's/^  version "\(.*\)"/\1/p')"
[[ "$TAPV" == "$V" ]] || { echo "WARNING: the cask says $TAPV, not $V."; exit 1; }
BINS="$(gh api "repos/destucr/homebrew-tap/contents/$CASK" --jq .content | base64 -d | grep -c '^  binary "' || true)"
[[ "$BINS" == "1" ]] || { echo "WARNING: the cask has $BINS binary lines, expected 1."; exit 1; }
echo "Verified: release and cask are both $V"
