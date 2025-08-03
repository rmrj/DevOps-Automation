#!/usr/bin/env bash
# Exit immediately on any error, treat unset variables as errors, and fail on pipe errors
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Determine the current Kubernetes namespace
#    - Uses the namespace currently selected by kubens (or kubectl config)
#    - If none is set, defaults to "default"
# -----------------------------------------------------------------------------
NS=$(kubectl config view --minify -o jsonpath='{..namespace}')
: "${NS:=default}"
echo "Using Kubernetes namespace: $NS"

# -----------------------------------------------------------------------------
# 2. Configuration variables
#    - PROJECT: GCP project where your existing disks and snapshots live
#    - SC:      StorageClass to assign to the new “-hd” disks
# -----------------------------------------------------------------------------
PROJECT=<GCP project>
SC=hyperdisk-balanced # depends on what type of machine you're using for the node pool

# -----------------------------------------------------------------------------
# 3. Verify required CLI tools are available
#    - kubectl: to interact with Kubernetes
#    - jq:      to render JSON transformations
#    - gcloud:  to snapshot and clone GCE disks
# -----------------------------------------------------------------------------
for cmd in kubectl jq gcloud; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: required command '$cmd' not found; please install it."
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# 4. Build the list of StatefulSets to process
#    - If the user passed names on the command line, process only those
#    - Otherwise, query all StatefulSets in the current namespace
# -----------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  # Use the command-line arguments as the list of STS names
  STS_ARRAY=( "$@" )
else
  # Query Kubernetes for all StatefulSet names, then iterate
  STS_ARRAY=()
  for name in $(kubectl -n "$NS" get sts -o jsonpath='{.items[*].metadata.name}'); do
    STS_ARRAY+=( "$name" )
  done
fi

# -----------------------------------------------------------------------------
# 5. Main processing loop
#    For each StatefulSet:
#      A) Skip if it already has “-hd” volumes attached
#      B) Scale down to zero replicas
#      C) For every matching PVC:
#         1) Identify the underlying GCE disk
#         2) Wait for it to detach
#         3) Snapshot it
#         4) Create a new “-hd” disk from that snapshot
#         5) Provision a corresponding PV and PVC
#      D) Export a minimal YAML of the StatefulSet, injecting only the new -hd PVC
#      E) Delete the original StatefulSet, reapply the patched version, and scale back up
# -----------------------------------------------------------------------------
for STS in "${STS_ARRAY[@]}"; do
  echo
  echo "Starting migration for StatefulSet: $STS"

  # Check if this STS already references any PVC ending in “-hd”
  if kubectl -n "$NS" get sts "$STS" \
       -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}' \
       | grep -q -- '-hd'; then
    echo "  Migration already completed for $STS; skipping"
    continue
  fi

  # Capture the original replica count so we can restore it later
  orig_replicas=$(kubectl -n "$NS" get sts "$STS" -o jsonpath='{.spec.replicas}')

  # Determine the PVC template name (guaranteed ≤ 63 characters)
  # This is the basis for naming our new disks, PVs, and PVCs
  tmpl_name=$(kubectl -n "$NS" get sts "$STS" \
                -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}')
  echo "  Using volumeClaimTemplate name: $tmpl_name"

  # Scale the StatefulSet down to zero to release all volumes
  echo "  Scaling StatefulSet/$STS down to 0 replicas"
  kubectl -n "$NS" scale sts/"$STS" --replicas=0

  # Enumerate all PVCs in this namespace that belong to this STS and are not already “-hd”
  # Snapshot & clone each matching PVC
  echo "  Retrieving non-hd PVCs for $STS"
  PVC_LIST=$(kubectl -n "$NS" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
               | grep "^${tmpl_name}-" \
               | grep -v '\-hd$')

  # Process each PVC: snapshot and clone into a new “-hd” disk
  for pvc in $PVC_LIST; do
    echo "    Processing PVC: $pvc"

    # Find the bound PV name
    pv=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')

    # Attempt to extract the GCE disk name from in-tree spec
    pd=$(kubectl get pv "$pv" -o jsonpath='{.spec.gcePersistentDisk.pdName}' 2>/dev/null || true)
    if [ -z "$pd" ]; then
      # Otherwise fall back to the CSI volume handle
      vh=$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)
      pd=${vh##*/}
    fi
    if [ -z "$pd" ]; then
      echo "      ERROR: no GCE disk found for PV $pv; skipping"
      continue
    fi

    # Discover which zone the disk lives in
    zone=$(gcloud compute disks list \
             --project="$PROJECT" \
             --filter="name~${pd}\$" \
             --format='value(zone.basename())' | head -1)
    if [ -z "$zone" ]; then
      echo "      ERROR: disk $pd not found in any zone; aborting"
      exit 1
    fi

    # Wait until the disk is fully detached
    echo "      Waiting for disk $pd to detach"
    until ! gcloud compute disks describe "$pd" \
                --project="$PROJECT" --zone="$zone" \
                --format='value(users)' | grep -q .; do
      sleep 5
    done

    # Generate Unix timestamp like 1751225960.
    # -c6 hands you the last six bytes of its input.
    # stamp=$(date +%s | tail -c6)
    stamp=$(date +%s | tr -d '\n' | tail -c6)
    stamp_len=${#stamp}

    # GCE names must be ≤63 chars
    max_total=63

    # for snapshot: suffix is "-<stamp>" (1 hyphen + stamp)
    snap_suffix_len=$((1 + stamp_len))
    snap_room=$((max_total - snap_suffix_len))
    #guarantees your prefixes are the right size.
    # take characters 1 through $snap_room
    base_snap=${tmpl_name:0:snap_room}
    # strip any trailing hyphens
    base_snap=${base_snap%-}

    # for new disk: suffix is "-hd-<stamp>" (4 chars + stamp)
    disk_suffix_len=$((4 + stamp_len))  # "-hd-" + stamp
    disk_room=$((max_total - disk_suffix_len))
    # take characters 1 through $disk_room
    base_disk=${tmpl_name:0:disk_room}
    # strip any trailing hyphens
    base_disk=${base_disk%-}

    snapshot_name="${base_snap}-${stamp}"
    newdisk="${base_disk}-hd-${stamp}"
    pvname="${pvc}-hd-pv"
    pvcname="${pvc}-hd"
    size=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}')

    # Snapshot
    echo "      Creating snapshot: $snapshot_name"
    gcloud compute disks snapshot "$pd" \
      --snapshot-names="$snapshot_name" \
      --zone="$zone" \
      --project="$PROJECT"

    # New disk
    echo "      Creating new disk: $newdisk"
    gcloud compute disks create "$newdisk" \
      --source-snapshot="$snapshot_name" \
      --type="$SC" \
      --zone="$zone" \
      --size="$size" \
      --project="$PROJECT"

    # Provision a corresponding PersistentVolume if it doesn’t already exist
    if ! kubectl get pv "$pvname" &>/dev/null; then
      echo "      Creating PersistentVolume: $pvname"
      kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $pvname
spec:
  capacity:
    storage: $size
  accessModes:
    - ReadWriteOnce
  storageClassName: $SC
  persistentVolumeReclaimPolicy: Retain
  gcePersistentDisk:
    pdName: $newdisk
    fsType: ext4
EOF
    else
      echo "      PersistentVolume $pvname already exists; skipping"
    fi

    # Provision a corresponding PersistentVolumeClaim if it doesn’t already exist
    if ! kubectl get pvc "$pvcname" -n "$NS" &>/dev/null; then
      echo "      Creating PersistentVolumeClaim: $pvcname"
      kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvcname
  namespace: $NS
spec:
  storageClassName: $SC
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $size
  volumeName: $pvname
EOF
    else
      echo "      PersistentVolumeClaim $pvcname already exists; skipping"
    fi
  done

# -----------------------------------------------------------------------------
# 6. Patch the StatefulSet manifest to bind to the new -hd PVC
# -----------------------------------------------------------------------------
# This section creates a minimal StatefulSet manifest using jq:
# - Preserves core spec values (replicas, selectors, etc.)
# - Removes the dynamic volumeClaimTemplate by deleting the original StatefulSet
# - Injects a static reference to the newly created PVC named $pvc
#
# This avoids Kubernetes errors that occur when trying to patch or edit volumeClaimTemplates.
  echo "  Patching StatefulSet definition for $STS"
  OUT_FILE="${PWD}/${STS}-minimal.yaml"
  kubectl -n "$NS" get sts "$STS" -o json \
    | jq --arg base "$tmpl_name" --arg pvc "$pvcname" '
{
  apiVersion: .apiVersion,
  kind:       .kind,
  metadata: {
    name:      .metadata.name,
    namespace: .metadata.namespace
  },
  spec: {
    serviceName:                          .spec.serviceName,
    replicas:                             .spec.replicas,
    podManagementPolicy:                  .spec.podManagementPolicy,
    updateStrategy:                       .spec.updateStrategy,
    persistentVolumeClaimRetentionPolicy: .spec.persistentVolumeClaimRetentionPolicy,
    selector:                             .spec.selector,
    template: {
      metadata: {
        labels:      .spec.template.metadata.labels,
        annotations: .spec.template.metadata.annotations
      },
      spec: {
        securityContext:    .spec.template.spec.securityContext,
        serviceAccountName: .spec.template.spec.serviceAccountName,
        # Remove any existing volume named $base, then add one volumeClaim to the new PVC
        # (.spec.template.spec.volumes // []) fetches the current list of volumes (or an empty array if none exist).
        # map(select(.name != $base)) walks that list and keeps only the entries whose .name is not equal to $base.  
        # In effect, it drops any volume whose name matches our target (this will remove stale or duplicate entries).
        volumes: (
          (.spec.template.spec.volumes // [])
          | map(select(.name != $base))
          + [
              {
                name: $base,
                persistentVolumeClaim: { claimName: $pvc }
              }
            ]
        ),
        initContainers: (.spec.template.spec.initContainers // []),
        containers:     .spec.template.spec.containers
      }
    }
  }
}
' >"$OUT_FILE"

  # Roll out the patched StatefulSet
  echo "  Deleting original StatefulSet/$STS"
  kubectl -n "$NS" delete sts "$STS"

  echo "  Applying patched StatefulSet from $OUT_FILE"
  kubectl -n "$NS" apply -f "$OUT_FILE"

  # Restore original replica count
  echo "  Scaling StatefulSet/$STS back to $orig_replicas replicas"
  kubectl -n "$NS" scale sts/"$STS" --replicas="$orig_replicas"

  echo "Completed migration for StatefulSet: $STS"
  echo
  echo "Post-migration checks for $STS:"
  echo "  Verifying new PVC is created and bound:"
  kubectl -n "$NS" get pvc | grep "$pvcname" || echo "    [WARN] PVC $pvcname not found."

  echo "  Verifying pod is using the new PVC:"
  # Note: This assumes your pods are labeled with app=$STS. Adjust the label selector if needed.
  kubectl -n "$NS" get pod -l app="$STS" -o jsonpath='{.items[*].spec.volumes[*].persistentVolumeClaim.claimName}' \
    | grep -q "$pvcname" && echo "    Pod is using new PVC: $pvcname" \
    || echo "    Pod may not be using expected PVC: $pvcname — please investigate."

  echo "  Current StatefulSet status:"
  kubectl -n "$NS" get sts "$STS"
done
