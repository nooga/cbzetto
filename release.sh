#!/bin/bash

# Release script for CBZetto
# Usage: ./release.sh [major|minor|patch]
# Default: patch

set -e

BUMP_TYPE="${1:-patch}"

if [[ ! "$BUMP_TYPE" =~ ^(major|minor|patch)$ ]]; then
    echo "Usage: ./release.sh [major|minor|patch]"
    echo "Default: patch"
    exit 1
fi

# Extract current version from build.zig.zon
CURRENT_VERSION=$(grep '\.version' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$CURRENT_VERSION" ]; then
    echo "Error: Could not extract version from build.zig.zon"
    exit 1
fi

echo "Current version: $CURRENT_VERSION"

# Parse semver
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Bump version
case "$BUMP_TYPE" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "New version: $NEW_VERSION"

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Update build.zig.zon
sed -i '' "s/\.version = \"$CURRENT_VERSION\"/\.version = \"$NEW_VERSION\"/" build.zig.zon
echo "Updated build.zig.zon"

# Update download link in docs/index.html
DMG_URL="https://github.com/nooga/cbzetto/releases/download/v${NEW_VERSION}/CBZetto-${NEW_VERSION}.dmg"
sed -i '' "s|href=\"https://github.com/nooga/cbzetto/releases/[^\"]*\" class=\"download-btn\"|href=\"${DMG_URL}\" class=\"download-btn\"|" docs/index.html
echo "Updated docs/index.html download link"

# Commit and tag
git add build.zig.zon docs/index.html
git commit -m "Bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo "Created commit and tag v$NEW_VERSION"

# Push
echo ""
read -p "Push commit and tag to origin? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    git push && git push --tags
    echo "Pushed! GitHub Actions will now build the release."
else
    echo "Skipped push. Run manually:"
    echo "  git push && git push --tags"
fi
