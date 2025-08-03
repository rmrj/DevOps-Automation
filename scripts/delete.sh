#!/bin/bash
set -euo pipefail

NODEPOOL="<YOUR-GKE-NODEPOOL-NAME>"

for NODE in $(kubectl get nodes -l cloud.google.com/gke-nodepool=$NODEPOOL -o name); do
  echo "Deleting $NODE..."
  kubectl delete "$NODE"
  echo "Sleeping for 10 seconds before deleting the next node..."
  sleep 10
done
