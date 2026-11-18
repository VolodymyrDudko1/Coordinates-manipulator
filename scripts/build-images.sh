#!/usr/bin/env bash
# Builds two versions of the backend image and loads them into minikube.
# Usage (from the repository root):  ./scripts/build-images.sh
# The `latest` tag is never used: Kubernetes always gets an explicit version.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-portal-api}"
cd "$(dirname "$0")/.."

build() {
  local version="$1" note="$2"
  echo ">>> Building ${IMAGE_NAME}:${version}"
  docker build \
    --file Dockerfile \
    --build-arg APP_VERSION="${version}" \
    --build-arg APP_RELEASE_NOTE="${note}" \
    --tag "${IMAGE_NAME}:${version}" \
    .
}

build 1.0.0 "Release 1.0.0: initial Kubernetes deployment"
build 1.1.0 "Release 1.1.0: NEW rolling update. If you see this, set image worked!"

# Copy the images from the local Docker daemon into the minikube node,
# so pods can start with imagePullPolicy: IfNotPresent without a registry.
for version in 1.0.0 1.1.0; do
  echo ">>> Loading ${IMAGE_NAME}:${version} into minikube"
  minikube image load "${IMAGE_NAME}:${version}"
done

echo ">>> Images available inside minikube:"
minikube image ls | grep "${IMAGE_NAME}" || true
