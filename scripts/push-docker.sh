#!/usr/bin/env bash
set -euo pipefail

# Usage: ./push-docker.sh <version> <tarball-directory>
# Example: ./push-docker.sh 1.0.0 /tmp/fr
#
# Requires:
# - podman
# - Files in <tarball-directory>:
#   - docker-image-feed-repeat-amd64.tar.gz
#   - docker-image-feed-repeat-aarch64.tar.gz
#
# Environment:
# - GHCR_TOKEN: GitHub token with write:packages scope (or use podman login interactively)

VERSION="${1:?Usage: $0 <version>}"
TAR_DIR="${2:?Usage: $0 <version> <tarball-directory>}"
GHCR_USER="${GHCR_USER:?Set GHCR_USER (e.g., your GitHub username)}"
IMAGE="ghcr.io/${GHCR_USER}/feed-repeat"

# Load images
echo "Loading amd64 image..."
podman load < "${TAR_DIR}/docker-image-feed-repeat-amd64.tar.gz"

echo "Loading aarch64 image..."
podman load < "${TAR_DIR}/docker-image-feed-repeat-aarch64.tar.gz"

# Tag images
echo "Tagging images..."
podman tag localhost/feed-repeat:latest "${IMAGE}:${VERSION}-amd64"
podman tag localhost/feed-repeat:latest "${IMAGE}:${VERSION}-arm64"

# Login to GHCR
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "Logging in to GHCR..."
  echo "${GHCR_TOKEN}" | podman login ghcr.io -u "${GHCR_USER}" --password-stdin
else
  echo "No GHCR_TOKEN set. You'll need to log in manually."
  podman login ghcr.io -u "${GHCR_USER}"
fi

# Push images
echo "Pushing amd64 image..."
podman push "${IMAGE}:${VERSION}-amd64"

echo "Pushing arm64 image..."
podman push "${IMAGE}:${VERSION}-arm64"

# Create and push multi-arch manifest
echo "Creating multi-arch manifest..."
podman manifest create "${IMAGE}:${VERSION}"
podman manifest add "${IMAGE}:${VERSION}" "docker://${IMAGE}:${VERSION}-amd64"
podman manifest add "${IMAGE}:${VERSION}" "docker://${IMAGE}:${VERSION}-arm64"

echo "Pushing manifest..."
podman manifest push "${IMAGE}:${VERSION}"

# Also push as latest
echo "Creating latest manifest..."
podman manifest create "${IMAGE}:latest"
podman manifest add "${IMAGE}:latest" "docker://${IMAGE}:${VERSION}-amd64"
podman manifest add "${IMAGE}:latest" "docker://${IMAGE}:${VERSION}-arm64"

echo "Pushing latest manifest..."
podman manifest push "${IMAGE}:latest"

echo "Done!"
echo "Images pushed:"
echo "  ${IMAGE}:${VERSION}"
echo "  ${IMAGE}:latest"
