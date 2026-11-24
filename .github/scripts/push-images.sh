#!/usr/bin/env bash
# Pushes both images to Docker Hub, but never overwrites a tag that already exists.
# Needs: DOCKERHUB_USER and IMAGE_TAG in the environment, and a completed "docker login".
# Why: a tag must point at exactly one build forever (design worksheet 2.2). If this pipeline
# is re-run for the same commit, the images already on Docker Hub are kept and reused.
set -euo pipefail

: "${DOCKERHUB_USER:?DOCKERHUB_USER is not set}"
: "${IMAGE_TAG:?IMAGE_TAG is not set}"

if ! [[ "$IMAGE_TAG" =~ ^sha-[0-9a-f]{7}$ ]]; then
  echo "::error::Refusing to push '$IMAGE_TAG'. A tag must look like sha-1a2b3c4, never latest."
  exit 2
fi

for svc in backend frontend; do
  image="$DOCKERHUB_USER/formflow-$svc:$IMAGE_TAG"
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    echo "$image already exists on Docker Hub. Not pushing it again."
  else
    echo "Pushing $image"
    docker push "$image"
  fi
done

for svc in backend frontend; do
  image="$DOCKERHUB_USER/formflow-$svc:$IMAGE_TAG"
  docker manifest inspect "$image" >/dev/null 2>&1 || { echo "::error::$image is not on Docker Hub after the push."; exit 1; }
done
echo "Both images are on Docker Hub with the tag $IMAGE_TAG."
