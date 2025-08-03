#!/bin/bash
set -euo pipefail

NODEPOOL="<YOUR-GKE-NODEPOOL-NAME>"

for NODE in $(kubectl get nodes -l cloud.google.com/gke-nodepool=$NODEPOOL -o name); do
  echo "Cordoning $NODE..."
  kubectl cordon "$NODE"
done
