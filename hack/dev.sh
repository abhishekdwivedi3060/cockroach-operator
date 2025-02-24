#!/usr/bin/env bash

# Copyright 2022 The Cockroach Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -euo pipefail

PATH="bazel-bin/hack/bin:${PATH}"

APP_VERSION="${APP_VERSION:-v$(cat version.txt)}"
CLUSTER_NAME="dev"
NODE_IMAGE="kindest/node:v1.22.1"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT=5000

run_local_registry() {
  running="$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)"
  if [ "${running}" == 'true' ]; then return; fi

  # start a local registry in docker
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2
}

create_kind_cluster() {
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
- role: control-plane
  image: ${NODE_IMAGE}
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."127.0.0.1:${REGISTRY_PORT}"]
    endpoint = ["http://${REGISTRY_NAME}:${REGISTRY_PORT}"]
EOF
}

setup_k8s_registry_hosting() {
  docker network connect "kind" "${REGISTRY_NAME}"

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "127.0.0.1:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

install_operator() {
  # Can't seem to figure out how to leverage the stamp variables here. So for
  # now I've added a defined make variable which can be used for substitution
  # in //config/default/BUILD.bazel.
  K8S_CLUSTER="kind-${CLUSTER_NAME}" \
    DEV_REGISTRY="127.0.0.1:${REGISTRY_PORT}" \
    bazel run \
    --stamp \
    --platforms=@io_bazel_rules_go//go/toolchain:linux_amd64 \
    --define APP_VERSION=${APP_VERSION} \
    //config/default:install.apply
}

wait_for_ready() {
  echo "Waiting for deployment to be available..."
  kubectl wait \
    --for=condition=Available \
    --timeout=2m \
    -n cockroach-operator-system \
    deploy/cockroach-operator-manager
}

main() {
  case "${1:-}" in
    up)
    run_local_registry
    create_kind_cluster
    setup_k8s_registry_hosting
    install_operator
    wait_for_ready;;
    down)
      kind delete cluster --name "${CLUSTER_NAME}"
      docker rm -f "${REGISTRY_NAME}" 2>/dev/null || true;;
    *) echo "Unknown command. Usage $0 <up|down>" 1>&2; exit 1;;
  esac
}

main "$@"
