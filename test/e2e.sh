#!/usr/bin/env bash
#
# E2E tests for the Memcached CRD managed by sample-controller.
# Requires: kubectl connected to a cluster with the Memcached CRD already installed
#           and the sample-controller running.
#
# Usage:
#   ./hack/e2e-test.sh
#
# The script exits with 0 on success, 1 on any test failure.

set -euo pipefail

TEST_NS="controller-e2e-test-$(date +%s)"
PASS=0
FAIL=0
TESTS_RUN=0

# ---------- helpers ----------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[PASS]\033[0m  $*"; PASS=$((PASS+1)); TESTS_RUN=$((TESTS_RUN+1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; FAIL=$((FAIL+1)); TESTS_RUN=$((TESTS_RUN+1)); }

# wait_for_condition polls until a jsonpath expression on a resource matches
# an expected value, or times out.
#   $1 = resource (e.g. deployment/my-dep)
#   $2 = jsonpath expression
#   $3 = expected value
#   $4 = timeout in seconds (default 60)
wait_for_condition() {
  local resource="$1" jsonpath="$2" expected="$3" timeout="${4:-60}"
  local deadline=$((SECONDS + timeout))
  while true; do
    local actual
    actual=$(kubectl get "$resource" -n "$TEST_NS" -o jsonpath="$jsonpath" 2>/dev/null || echo "")
    if [[ "$actual" == "$expected" ]]; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "  timed out waiting for $resource $jsonpath == $expected (last: $actual)"
      return 1
    fi
    sleep 2
  done
}

# wait_for_deletion polls until a resource no longer exists, or times out.
#   $1 = resource (e.g. deployment/my-dep)
#   $2 = timeout in seconds (default 60)
wait_for_deletion() {
  local resource="$1" timeout="${2:-60}"
  local deadline=$((SECONDS + timeout))
  while true; do
    if ! kubectl get "$resource" -n "$TEST_NS" &>/dev/null; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "  timed out waiting for $resource to be deleted"
      return 1
    fi
    sleep 2
  done
}

cleanup() {
  info "Cleaning up namespace $TEST_NS"
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ---------- setup ----------

trap cleanup EXIT

info "Creating test namespace: $TEST_NS"
kubectl create namespace "$TEST_NS"

# ===================================================================
# TEST 1: Basic create — Memcached creates a Deployment
# ===================================================================
info "TEST 1: Create a Memcached and verify Deployment is created"
kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-basic
spec:
  deploymentName: test-basic-dep
  size: 1
EOF

if wait_for_condition "deployment/test-basic-dep" "{.spec.replicas}" "1"; then
  ok "TEST 1: Deployment test-basic-dep created with 1 replica"
else
  fail "TEST 1: Deployment test-basic-dep was not created"
fi

# ===================================================================
# TEST 2: Verify Deployment has correct owner reference
# ===================================================================
info "TEST 2: Verify Deployment owner reference points to Memcached"
OWNER_KIND=$(kubectl get deployment/test-basic-dep -n "$TEST_NS" \
  -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
OWNER_NAME=$(kubectl get deployment/test-basic-dep -n "$TEST_NS" \
  -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "")

if [[ "$OWNER_KIND" == "Memcached" && "$OWNER_NAME" == "test-basic" ]]; then
  ok "TEST 2: OwnerReference kind=Memcached, name=test-basic"
else
  fail "TEST 2: OwnerReference mismatch (kind=$OWNER_KIND, name=$OWNER_NAME)"
fi

# ===================================================================
# TEST 3: Verify Deployment labels
# ===================================================================
info "TEST 3: Verify Deployment pod template has expected labels"
APP_LABEL=$(kubectl get deployment/test-basic-dep -n "$TEST_NS" \
  -o jsonpath='{.spec.template.metadata.labels.app}' 2>/dev/null || echo "")
CTRL_LABEL=$(kubectl get deployment/test-basic-dep -n "$TEST_NS" \
  -o jsonpath='{.spec.template.metadata.labels.controller}' 2>/dev/null || echo "")

if [[ "$APP_LABEL" == "nginx" && "$CTRL_LABEL" == "test-basic" ]]; then
  ok "TEST 3: Labels app=nginx, controller=test-basic"
else
  fail "TEST 3: Labels mismatch (app=$APP_LABEL, controller=$CTRL_LABEL)"
fi

# ===================================================================
# TEST 4: Verify Deployment uses nginx container
# ===================================================================
info "TEST 4: Verify Deployment container image is nginx"
IMAGE=$(kubectl get deployment/test-basic-dep -n "$TEST_NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [[ "$IMAGE" == "memcached:1.4.36-alpine" ]]; then
  ok "TEST 4: Container image is memcached:1.4.36-alpine"
else
  fail "TEST 4: Container image mismatch ($IMAGE)"
fi

# ===================================================================
# TEST 5: Scale up — update size in Memcached
# ===================================================================
info "TEST 5: Scale Memcached size from 1 to 3"
kubectl patch memcached test-basic -n "$TEST_NS" --type merge -p '{"spec":{"size":3}}'

if wait_for_condition "deployment/test-basic-dep" "{.spec.replicas}" "3"; then
  ok "TEST 5: Deployment scaled to 3 size"
else
  fail "TEST 5: Deployment did not scale to 3 size"
fi

# ===================================================================
# TEST 6: Scale down — update size in Memcached
# ===================================================================
info "TEST 6: Scale Memcached size from 3 to 1"
kubectl patch memcached test-basic -n "$TEST_NS" --type merge -p '{"spec":{"size":1}}'

if wait_for_condition "deployment/test-basic-dep" "{.spec.replicas}" "1"; then
  ok "TEST 6: Deployment scaled down to 1 replica"
else
  fail "TEST 6: Deployment did not scale down to 1 replica"
fi

# ===================================================================
# TEST 7: CRD validation — size minimum boundary (1 is valid)
# ===================================================================
info "TEST 7: CRD validation - size=1 (minimum) should succeed"
if kubectl apply -n "$TEST_NS" -f - <<'EOF' 2>/dev/null
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-min-size
spec:
  deploymentName: test-min-dep
  size: 1
EOF
then
  ok "TEST 7: size=1 accepted (minimum boundary)"
else
  fail "TEST 7: size=1 rejected unexpectedly"
fi

# # ===================================================================
# # TEST 8: CRD validation — size maximum boundary (10 is valid)
# # ===================================================================
# info "TEST 8: CRD validation - size=10 (maximum) should succeed"
# if kubectl apply -n "$TEST_NS" -f - <<'EOF' 2>/dev/null
# apiVersion: cache.example.com/v1alpha1
# kind: Memcached
# metadata:
#   name: test-max-size
# spec:
#   deploymentName: test-max-dep
#   size: 10
# EOF
# then
#   ok "TEST 8: size=10 accepted (maximum boundary)"
# else
#   fail "TEST 8: size=10 rejected unexpectedly"
# fi

# # ===================================================================
# # TEST 9: CRD validation — size below minimum (0) should be rejected
# # ===================================================================
# info "TEST 9: CRD validation - size=0 should be rejected"
# if kubectl apply -n "$TEST_NS" -f - <<'EOF' 2>&1 | grep -qi 'invalid\|error\|denied\|minimum'; then
# apiVersion: cache.example.com/v1alpha1
# kind: Memcached
# metadata:
#   name: test-invalid-zero
# spec:
#   deploymentName: test-invalid-dep
#   size: 0
# EOF
#   ok "TEST 9: size=0 rejected by CRD validation"
# else
#   fail "TEST 9: size=0 was NOT rejected"
# fi

# # ===================================================================
# # TEST 10: CRD validation — size above maximum (11) should be rejected
# # ===================================================================
# info "TEST 10: CRD validation - size=11 should be rejected"
# if kubectl apply -n "$TEST_NS" -f - <<'EOF' 2>&1 | grep -qi 'invalid\|error\|denied\|maximum'; then
# apiVersion: cache.example.com/v1alpha1
# kind: Memcached
# metadata:
#   name: test-invalid-eleven
# spec:
#   deploymentName: test-invalid-dep2
#   size: 11
# EOF
#   ok "TEST 10: size=11 rejected by CRD validation"
# else
#   fail "TEST 10: size=11 was NOT rejected"
# fi

# ===================================================================
# TEST 11: Multiple Memcacheds in same namespace
# ===================================================================
info "TEST 11: Create a second Memcached in the same namespace"
kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-second
spec:
  deploymentName: test-second-dep
  size: 2
EOF

if wait_for_condition "deployment/test-second-dep" "{.spec.replicas}" "2"; then
  ok "TEST 11: Second Memcached created its own Deployment with 2 size"
else
  fail "TEST 11: Second Memcached did not create its Deployment"
fi

# # Verify first Memcached's deployment is still intact
# FIRST_REPLICAS=$(kubectl get deployment/test-basic-dep -n "$TEST_NS" \
#   -o jsonpath='{.spec.size}' 2>/dev/null || echo "")
# if [[ "$FIRST_REPLICAS" == "1" ]]; then
#   ok "TEST 11b: First Memcached's Deployment is unaffected (still 1 replica)"
# else
#   fail "TEST 11b: First Memcached's Deployment was affected (size=$FIRST_REPLICAS)"
# fi

# ===================================================================
# TEST 12: Deployment drift recovery — manual replica change is reconciled
# ===================================================================
info "TEST 12: Deployment drift recovery - manually scale deployment"
kubectl scale deployment/test-basic-dep -n "$TEST_NS" --replicas=5

if wait_for_condition "deployment/test-basic-dep" "{.spec.replicas}" "1" 30; then
  ok "TEST 12: Controller reconciled deployment back to 1 replica"
else
  fail "TEST 12: Controller did not reconcile deployment drift"
fi

# ===================================================================
# TEST 13: Delete Memcached — Deployment should be garbage-collected
# ===================================================================
info "TEST 13: Delete Memcached and verify Deployment is garbage-collected"
kubectl delete memcached test-basic -n "$TEST_NS" --wait=true

if wait_for_deletion "deployment/test-basic-dep" 60; then
  ok "TEST 13: Deployment garbage-collected after Memcached deletion"
else
  fail "TEST 13: Deployment was not garbage-collected"
fi

# ===================================================================
# TEST 14: Conflicting Deployment — pre-existing Deployment not owned by Memcached
# ===================================================================
info "TEST 14: Memcached referencing a pre-existing unowned Deployment"
# Create a standalone deployment first
kubectl create deployment test-conflict-dep -n "$TEST_NS" --image=memcached:1.4.36-alpine --replicas=1
sleep 2

kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-conflict
spec:
  deploymentName: test-conflict-dep
  size: 2
EOF

# The controller should emit a warning event since it doesn't own the deployment
sleep 5
EVENTS=$(kubectl get events -n "$TEST_NS" --field-selector reason=ErrResourceExists \
  -o jsonpath='{.items[*].message}' 2>/dev/null || echo "")

if echo "$EVENTS" | grep -q "test-conflict-dep"; then
  ok "TEST 14: ErrResourceExists event fired for pre-existing Deployment"
else
  fail "TEST 14: No ErrResourceExists event found (events: $EVENTS)"
fi

# ===================================================================
# TEST 15: List Memcacheds — kubectl get memcacheds
# ===================================================================
info "TEST 15: List all Memcacheds in namespace"
FOO_COUNT=$(kubectl get memcacheds -n "$TEST_NS" -o json | python3 -c \
  "import sys,json; print(len(json.load(sys.stdin)['items']))" 2>/dev/null || echo "0")

if (( FOO_COUNT >= 2 )); then
  ok "TEST 15: kubectl get memcacheds returned $FOO_COUNT items"
else
  fail "TEST 15: Expected at least 2 Memcacheds, got $FOO_COUNT"
fi

# # ===================================================================
# # TEST 16: Describe Memcached — verify describe output has expected fields
# # ===================================================================
# info "TEST 16: kubectl describe memcached shows spec fields"
# DESCRIBE_OUTPUT=$(kubectl describe memcached test-second -n "$TEST_NS" 2>/dev/null || echo "")

# if echo "$DESCRIBE_OUTPUT" | grep -q "Deployment Name:" || \
#    echo "$DESCRIBE_OUTPUT" | grep -q "deploymentName\|Replicas"; then
#   ok "TEST 16: kubectl describe shows spec fields"
# else
#   fail "TEST 16: kubectl describe output missing expected fields"
# fi

# ===================================================================
# TEST 17: Update deploymentName — should create a new Deployment
# ===================================================================
info "TEST 17: Update Memcached's deploymentName to point to a new Deployment"
kubectl patch memcached test-second -n "$TEST_NS" --type merge \
  -p '{"spec":{"deploymentName":"test-renamed-dep"}}'

if wait_for_condition "deployment/test-renamed-dep" "{.spec.replicas}" "2"; then
  ok "TEST 17: New Deployment test-renamed-dep created after rename"
else
  fail "TEST 17: New Deployment was not created after deploymentName change"
fi

# ===================================================================
# TEST 18: Memcached with size at boundary — exactly max (5)
# ===================================================================
info "TEST 18: Verify Deployment is created with max size (5)"
if wait_for_condition "deployment/test-max-dep" "{.spec.replicas}" "5" 30; then
  ok "TEST 18: Deployment with 5 size created successfully"
else
  fail "TEST 18: Deployment with 5 size not created"
fi

# ===================================================================
# TEST 19: Delete and recreate same Memcached name
# ===================================================================
info "TEST 19: Delete and recreate Memcached with the same name"
kubectl delete memcached test-min-size -n "$TEST_NS" --wait=true
wait_for_deletion "deployment/test-min-dep" 60 || true

kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-min-size
spec:
  deploymentName: test-min-dep-v2
  size: 2
EOF

if wait_for_condition "deployment/test-min-dep-v2" "{.spec.replicas}" "2"; then
  ok "TEST 19: Recreated Memcached with same name created new Deployment"
else
  fail "TEST 19: Recreated Memcached did not create its Deployment"
fi

# ===================================================================
# TEST 20: Memcached status reflects available size
# ===================================================================
info "TEST 20: Verify Memcached status.availableReplicas is updated"
# Use a simple Memcached and wait for pods to become available
kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-status
spec:
  deploymentName: test-status-dep
  size: 1
EOF

wait_for_condition "deployment/test-status-dep" "{.spec.replicas}" "1" 30 || true
# Wait for the deployment to have at least one available replica
if wait_for_condition "deployment/test-status-dep" "{.status.availableReplicas}" "1" 120; then
  # Give the controller a moment to sync the status back to the Memcached
  sleep 5
  AVAIL=$(kubectl get memcached test-status -n "$TEST_NS" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "")
  if [[ "$AVAIL" == "1" ]]; then
    ok "TEST 20: Memcached status.availableReplicas = 1"
  else
    fail "TEST 20: Memcached status.availableReplicas = $AVAIL (expected 1)"
  fi
else
  fail "TEST 20: Deployment never became available (pods may not schedule)"
fi

# ===================================================================
# TEST 21: Negative value for size should be rejected
# ===================================================================
info "TEST 21: CRD validation - size=-1 should be rejected"
if kubectl apply -n "$TEST_NS" -f - <<'EOF' 2>&1 | grep -qi 'invalid\|error\|denied\|minimum'; then
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-negative
spec:
  deploymentName: test-neg-dep
  size: -1
EOF
  ok "TEST 21: size=-1 rejected by CRD validation"
else
  fail "TEST 21: size=-1 was NOT rejected"
fi

# ===================================================================
# TEST 22: Very large invalid size should be rejected
# ===================================================================
info "TEST 22: CRD validation - size=100 should be rejected"
if kubectl apply -n "$TEST_NS" -f - <<'EOF' 2>&1 | grep -qi 'invalid\|error\|denied\|maximum'; then
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-large
spec:
  deploymentName: test-large-dep
  size: 100
EOF
  ok "TEST 22: size=100 rejected by CRD validation"
else
  fail "TEST 22: size=100 was NOT rejected"
fi

# ===================================================================
# TEST 23: Batch create — multiple Memcacheds created simultaneously
# ===================================================================
info "TEST 23: Batch create multiple Memcacheds at once"
for i in $(seq 1 5); do
  kubectl apply -n "$TEST_NS" -f - <<BATCHEOF &
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-batch-${i}
spec:
  deploymentName: test-batch-dep-${i}
  size: ${i}
BATCHEOF
done
wait  # wait for all background kubectl applies

BATCH_OK=true
for i in $(seq 1 5); do
  if ! wait_for_condition "deployment/test-batch-dep-${i}" "{.spec.replicas}" "${i}" 60; then
    fail "TEST 23: Deployment test-batch-dep-${i} not created with ${i} size"
    BATCH_OK=false
    break
  fi
done
if $BATCH_OK; then
  ok "TEST 23: All 5 batch Memcacheds created their Deployments with correct size"
fi

# ===================================================================
# TEST 24: Each Memcached's Deployment has independent owner references
# ===================================================================
info "TEST 24: Verify each batch Deployment is owned by its own Memcached"
OWNER_OK=true
for i in $(seq 1 5); do
  OWNER=$(kubectl get deployment "test-batch-dep-${i}" -n "$TEST_NS" \
    -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "")
  if [[ "$OWNER" != "test-batch-${i}" ]]; then
    fail "TEST 24: test-batch-dep-${i} owned by '$OWNER', expected 'test-batch-${i}'"
    OWNER_OK=false
    break
  fi
done
if $OWNER_OK; then
  ok "TEST 24: All batch Deployments have correct independent owner references"
fi

# ===================================================================
# TEST 25: Concurrent scaling — update multiple Memcacheds' size at once
# ===================================================================
info "TEST 25: Concurrently scale all batch Memcacheds to 3 size"
for i in $(seq 1 5); do
  kubectl patch memcached "test-batch-${i}" -n "$TEST_NS" --type merge \
    -p '{"spec":{"size":3}}' &
done
wait

SCALE_OK=true
for i in $(seq 1 5); do
  if ! wait_for_condition "deployment/test-batch-dep-${i}" "{.spec.replicas}" "3" 60; then
    fail "TEST 25: test-batch-dep-${i} did not scale to 3"
    SCALE_OK=false
    break
  fi
done
if $SCALE_OK; then
  ok "TEST 25: All 5 Deployments scaled to 3 size concurrently"
fi

# ===================================================================
# TEST 26: Deleting one Memcached does not affect other Memcacheds or Deployments
# ===================================================================
info "TEST 26: Delete one Memcached, verify others are unaffected"
kubectl delete memcached test-batch-3 -n "$TEST_NS" --wait=true

if wait_for_deletion "deployment/test-batch-dep-3" 60; then
  ok "TEST 26a: Deployment test-batch-dep-3 garbage-collected"
else
  fail "TEST 26a: Deployment test-batch-dep-3 not garbage-collected"
fi

# Check remaining Memcacheds and their Deployments are intact
INTACT_OK=true
for i in 1 2 4 5; do
  EXISTS=$(kubectl get memcached "test-batch-${i}" -n "$TEST_NS" -o name 2>/dev/null || echo "")
  DEP_REPLICAS=$(kubectl get deployment "test-batch-dep-${i}" -n "$TEST_NS" \
    -o jsonpath='{.spec.size}' 2>/dev/null || echo "")
  if [[ -z "$EXISTS" || "$DEP_REPLICAS" != "3" ]]; then
    fail "TEST 26b: test-batch-${i} or its Deployment was affected by deleting test-batch-3"
    INTACT_OK=false
    break
  fi
done
if $INTACT_OK; then
  ok "TEST 26b: Remaining 4 Memcacheds and Deployments unaffected"
fi

# ===================================================================
# TEST 27: Bulk delete — delete all remaining batch Memcacheds
# ===================================================================
info "TEST 27: Bulk delete multiple Memcacheds, all Deployments garbage-collected"
for i in 1 2 4 5; do
  kubectl delete memcached "test-batch-${i}" -n "$TEST_NS" --wait=false &
done
wait

BULK_OK=true
for i in 1 2 4 5; do
  if ! wait_for_deletion "deployment/test-batch-dep-${i}" 60; then
    fail "TEST 27: Deployment test-batch-dep-${i} not garbage-collected"
    BULK_OK=false
    break
  fi
done
if $BULK_OK; then
  ok "TEST 27: All batch Deployments garbage-collected after bulk Memcached deletion"
fi

# ===================================================================
# TEST 28: Multiple Memcacheds with same deploymentName — second Memcached gets conflict
# ===================================================================
info "TEST 28: Two Memcacheds pointing to the same deploymentName"
kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-dup-owner-a
spec:
  deploymentName: test-shared-dep
  size: 1
EOF

wait_for_condition "deployment/test-shared-dep" "{.spec.replicas}" "1" 30 || true

kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-dup-owner-b
spec:
  deploymentName: test-shared-dep
  size: 2
EOF

sleep 5
DUP_EVENTS=$(kubectl get events -n "$TEST_NS" --field-selector reason=ErrResourceExists \
  -o jsonpath='{.items[*].involvedObject.name}' 2>/dev/null || echo "")

if echo "$DUP_EVENTS" | grep -q "test-dup-owner-b"; then
  ok "TEST 28: Second Memcached gets ErrResourceExists for shared deploymentName"
else
  fail "TEST 28: No conflict event for second Memcached (events: $DUP_EVENTS)"
fi

# Verify the Deployment is still owned by the first Memcached
DUP_OWNER=$(kubectl get deployment test-shared-dep -n "$TEST_NS" \
  -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "")
if [[ "$DUP_OWNER" == "test-dup-owner-a" ]]; then
  ok "TEST 28b: Deployment remains owned by first Memcached (test-dup-owner-a)"
else
  fail "TEST 28b: Deployment owner changed to '$DUP_OWNER'"
fi

# ===================================================================
# TEST 29: Rapid update storm — many quick patches on the same Memcached
# ===================================================================
info "TEST 29: Rapid sequential updates to the same Memcached"
kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-rapid
spec:
  deploymentName: test-rapid-dep
  size: 1
EOF

wait_for_condition "deployment/test-rapid-dep" "{.spec.replicas}" "1" 30 || true

# Fire off rapid replica changes 1→2→3→4→5
for r in 2 3 4 5; do
  kubectl patch memcached test-rapid -n "$TEST_NS" --type merge \
    -p "{\"spec\":{\"size\":${r}}}"
done

# The controller should converge to the final value
if wait_for_condition "deployment/test-rapid-dep" "{.spec.replicas}" "5" 60; then
  ok "TEST 29: Controller converged to final replica count (5) after rapid updates"
else
  ACTUAL=$(kubectl get deployment test-rapid-dep -n "$TEST_NS" \
    -o jsonpath='{.spec.size}' 2>/dev/null || echo "?")
  fail "TEST 29: Controller did not converge (expected 5, got $ACTUAL)"
fi

# ===================================================================
# TEST 30: Cross-namespace isolation — Memcacheds in different namespaces
# ===================================================================
SECOND_NS="memcached-e2e-cross-$(date +%s)"
info "TEST 30: Memcached resources are isolated across namespaces"
kubectl create namespace "$SECOND_NS"

kubectl apply -n "$SECOND_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-cross-ns
spec:
  deploymentName: test-cross-dep
  size: 2
EOF

if wait_for_condition "deployment/test-cross-dep" "{.spec.replicas}" "2" 30; then
  # Verify the primary namespace has no spillover
  CROSS_CHECK=$(kubectl get deployment test-cross-dep -n "$TEST_NS" 2>&1 || echo "NotFound")
  if echo "$CROSS_CHECK" | grep -qi "NotFound\|not found"; then
    ok "TEST 30: Memcached in $SECOND_NS created Deployment only in its own namespace"
  else
    fail "TEST 30: Deployment leaked into $TEST_NS"
  fi
else
  fail "TEST 30: Deployment not created in second namespace"
fi

# Clean up second namespace
kubectl delete namespace "$SECOND_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ===================================================================
# TEST 31: Delete Memcached while Deployment is scaling — no orphaned Deployment
# ===================================================================
info "TEST 31: Delete Memcached while Deployment is mid-scale"
kubectl apply -n "$TEST_NS" -f - <<'EOF'
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-midscale
spec:
  deploymentName: test-midscale-dep
  size: 1
EOF

wait_for_condition "deployment/test-midscale-dep" "{.spec.replicas}" "1" 30 || true

# Scale up then immediately delete
kubectl patch memcached test-midscale -n "$TEST_NS" --type merge -p '{"spec":{"size":3}}'
kubectl delete memcached test-midscale -n "$TEST_NS" --wait=false

if wait_for_deletion "deployment/test-midscale-dep" 60; then
  ok "TEST 31: Deployment cleaned up even when deleted mid-scale"
else
  fail "TEST 31: Deployment orphaned after mid-scale deletion"
fi

# ===================================================================
# TEST 32: Controller handles interleaved create-delete-create
# ===================================================================
info "TEST 32: Interleaved create-delete-create cycle"
for cycle in 1 2 3; do
  kubectl apply -n "$TEST_NS" -f - <<CYCLEEOF
apiVersion: cache.example.com/v1alpha1
kind: Memcached
metadata:
  name: test-cycle
spec:
  deploymentName: test-cycle-dep
  size: ${cycle}
CYCLEEOF
  wait_for_condition "deployment/test-cycle-dep" "{.spec.replicas}" "${cycle}" 30 || true
  if [[ "$cycle" -lt 3 ]]; then
    kubectl delete memcached test-cycle -n "$TEST_NS" --wait=true
    wait_for_deletion "deployment/test-cycle-dep" 30 || true
  fi
done

CYCLE_REPLICAS=$(kubectl get deployment test-cycle-dep -n "$TEST_NS" \
  -o jsonpath='{.spec.size}' 2>/dev/null || echo "")
if [[ "$CYCLE_REPLICAS" == "3" ]]; then
  ok "TEST 32: Interleaved create-delete-create converged (size=3)"
else
  fail "TEST 32: Final cycle Deployment has size=$CYCLE_REPLICAS (expected 3)"
fi

# ---------- summary ----------

echo ""
echo "============================================"
echo "  E2E Test Summary"
echo "============================================"
echo "  Total:  $TESTS_RUN"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "============================================"

if (( FAIL > 0 )); then
  exit 1
fi
