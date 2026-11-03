#!/bin/bash
# Puts the release Scripts/make-release.sh made on the repository's GitHub Pages, where Overlap's install page
# and update feed live: https://chasingux.github.io/Overlap/
#
#   Scripts/publish-release.sh
#
# The site is the gh-pages branch, kept checked out in build/gh-pages. This copies in the feed, every version's
# zip, the newest zip for first installs, and the install page and its icon from Pages/, then commits and pushes. GitHub
# serves the change within a minute or two.
set -euo pipefail

repo="ChasingUX/Overlap"
url="https://chasingux.github.io/Overlap/"
root=$(cd "$(dirname "$0")/.." && pwd)
releases="$root/build/Releases"
site="$root/build/gh-pages"

if [[ ! -f $releases/appcast.xml || ! -f $releases/Overlap.zip ]]; then
    echo "Make a release first: Scripts/make-release.sh <version>" >&2
    exit 1
fi
version=$(cat "$releases/version.txt")

if [[ ! -d $site ]]; then
    git -C "$root" fetch origin gh-pages 2>/dev/null || true
    if git -C "$root" rev-parse --verify --quiet refs/remotes/origin/gh-pages > /dev/null; then
        git -C "$root" worktree add "$site" gh-pages
    else
        git -C "$root" worktree add --orphan -b gh-pages "$site"
    fi
fi
git -C "$site" pull --ff-only origin gh-pages 2>/dev/null || true

mkdir -p "$site/updates"
cp "$releases/updates/"*.zip "$site/updates/"
cp "$releases/appcast.xml" "$releases/Overlap.zip" "$site/"
cp -R "$root/Pages/." "$site/"
# Served as plain files, without GitHub's Jekyll step.
touch "$site/.nojekyll"

git -C "$site" add -A
if git -C "$site" diff --cached --quiet; then
    echo "Nothing new to publish."
else
    git -C "$site" commit -q -m "Release $version"
    git -C "$site" push -q -u origin gh-pages
fi

# The first time, turn GitHub Pages on for the branch. GitHub may already have done it on its own when the branch
# first arrived, and then answers that it's on.
if ! gh api "repos/$repo/pages" > /dev/null 2>&1; then
    gh api -X POST "repos/$repo/pages" -f "source[branch]=gh-pages" -f "source[path]=/" > /dev/null 2>&1 \
        || gh api "repos/$repo/pages" > /dev/null
fi

echo "Published Overlap $version at $url"
