#!/bin/bash
set -euo pipefail

NODEPOOL="<YOUR-GKE-NODEPOOL-NAME>"

for NODE in $(kubectl get nodes -l cloud.google.com/gke-nodepool=$NODEPOOL -o name); do
  echo "Draining $NODE..."
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
  echo "Sleeping for 120 seconds before draining the next node..."
  sleep 120
done
