#!/bin/zsh
# Brings both string catalogs up to date with the code: adds every new text the app shows,
# and marks texts that are no longer used as stale. Run it after changing what the app says,
# then add the translations (docs/localization.md). Needs Xcode's command line tools.
#
#   Tools/update-strings.sh
#
# While building, the Swift compiler lists every localizable text it sees (Text("…"),
# Button("…"), String(localized: "…"), LocalizedStringKey parameters) in a .stringsdata file
# per source file, the same way Xcode does it; xcstringstool merges them into the catalogs.
set -e
cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || { echo "The build failed; run swift build to see why."; exit 1; }

# Each .stringsdata names the source file it came from. A file can be compiled more than once
# (for the app and for the tests), so keep the newest list per source file, and skip files
# that no longer exist.
typeset -A newest
for f in .build/**/Intermediates.noindex/**/*.stringsdata(N.om); do
    src=$(grep -o '"source" *: *"[^"]*"' "$f" | sed 's/.*: *"//; s/"$//')
    [[ -f "$src" && -z "${newest[$src]}" ]] && newest[$src]="$f"
done

for target in CueVideo CueATEM; do
    catalog="Sources/$target/Resources/Localizable.xcstrings"
    files=()
    for src f in ${(kv)newest}; do
        [[ "$src" == "$PWD/Sources/$target/"* ]] && files+=("$f")
    done
    [ ${#files} -eq 0 ] && continue
    xcrun xcstringstool sync "$catalog" --stringsdata "${files[@]}"
    echo "Updated $catalog from ${#files} source files"
done
