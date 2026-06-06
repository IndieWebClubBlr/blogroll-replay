#!/usr/bin/env nix-shell
#! nix-shell -i bash -p pandoc
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
mkdir -p docs
touch docs/.nojekyll

# Generate index.html from README
pandoc --standalone --embed-resources --css docs/light.css --metadata title="feed-repeat" README.md -o docs/index.html

# Generate CHANGELOG.html from CHANGELOG
pandoc --standalone --embed-resources --css docs/light.css --metadata title="Changelog — feed-repeat" CHANGELOG.md -o docs/CHANGELOG.html

# Fix CHANGELOG.md link in index.html to point to CHANGELOG.html
sed -i 's#href="CHANGELOG\.md"#href="CHANGELOG.html"#g' docs/index.html

# Remove the title-block-header (pandoc duplicates the title from --metadata)
for f in docs/index.html docs/CHANGELOG.html; do
  sed -i '/^<header id="title-block-header">$/,/^<\/header>$/d' "$f"
done

# Add navigation bar to both pages (after <body>)
for f in docs/index.html docs/CHANGELOG.html; do
  sed -i "s#<body>#<body>\n<nav><a href=\"index.html\">Home</a> | <a href=\"CHANGELOG.html\">Changelog</a> | <a href=\"https://github.com/abhin4v/feed-repeat\">Source</a></nav>\n#" "$f"
done

echo "Site built in docs/"
