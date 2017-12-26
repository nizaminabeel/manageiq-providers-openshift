#!/bin/bash

set -e  # abort on error

echo '===== Ensure API server ====='

if [ -z "$OPENSHIFT_MASTER_HOST" ]; then
  echo "OPENSHIFT_MASTER_HOST unset, trying minishift"
  if which minishift && minishift status | grep -i 'openshift:.*running'; then
    export OPENSHIFT_MASTER_HOST="$(minishift ip)"
    eval $(minishift oc-env --shell bash) # Ensure oc in PATH
    oc login -u system:admin # With minishift, we know we can just do this
  else
    echo 'Either set $OPENSHIFT_MASTER_HOST and perform `oc login` with admin powers,'
    echo 'or have minishift in $PATH and already running, e.g.'
    echo '    minishift addons enable manageiq'
    echo '    minishift start --vm-driver virtualbox --openshift-version v3.7.0'
    exit 1
  fi
fi

if [ -z "$OPENSHIFT_MANAGEMENT_ADMIN_TOKEN" ]; then
  export OPENSHIFT_MANAGEMENT_ADMIN_TOKEN="$(oc sa get-token -n management-infra management-admin)"
fi

cd "$(git rev-parse --show-toplevel)" # repo root
VCR_DIR=./spec/vcr_cassettes/manageiq/providers/openshift/container_manager/
SPEC=./spec/models/manageiq/providers/openshift/container_manager/refresher_spec.rb

echo; echo "===== Clean slate, create objects ====="

oc delete --ignore-not-found project my-project-{0,1,2}

while oc get --show-all projects | grep my-project; do
  echo "... waiting for projects to disappear ..."
  sleep 3
done

for ind in 0 1 2; do
  oc new-project my-project-$ind
  oc project my-project-$ind
  # Some objects here require the admin priviledges we got above.
  oc process -f "$VCR_DIR"/test_objects_template.yml -v INDEX=$ind | oc create -f -

  oc start-build my-build-config-$ind
done

while OUT="$(oc get build --all-namespaces)"; echo "$OUT"; [ "$(echo "$OUT" | egrep --count --word 'Complete|Failed|Error')" -ne 3 ]; do
  echo "... waiting for builds to complete ..."
  sleep 3
done

echo; echo "===== Record first VCR ====="

describe_vcr () {
  echo "VCR generated by $0 against $OPENSHIFT_MASTER_HOST"
  echo
  oc version
  echo
  echo "CAVEAT: status shown here might differ from moment captured in VCR!"
  echo "== oc get projects --show-all --show-kind --show-labels =="
  oc get projects --show-all --show-kind --show-labels
  echo
  echo "== oc get all --show-all --all-namespaces -o wide --show-labels =="
  oc get all --show-all --all-namespaces -o wide --show-labels
  echo
  echo "== oc get images =="
  oc get images
}

# Deleting VCR file allows using :new_episodes so multiple specs calling refresh
# is not a problem, only the first will re-record the VCR.
rm -v "$VCR_DIR"/refresher_before_deletions.{yml,txt} || true
describe_vcr > "$VCR_DIR"/refresher_before_deletions.txt
env RECORD_VCR=before_deletions bundle exec rspec "$SPEC" || echo "^^ FAILURES ARE POSSIBLE, YOU'LL HAVE TO EDIT THE SPEC"

echo; echo "===== Various deletions ====="

oc delete project my-project-0

oc project my-project-1
oc delete pod my-pod-1
oc delete service my-service-1
oc delete route my-route-1
oc delete resourceQuota my-resource-quota-1
oc delete limitRange my-limit-range-1
oc delete persistentVolumeClaim my-persistentvolumeclaim-1
oc delete template my-template-1
oc delete buildconfig my-build-config-1 # also deletes its build(s)
oc delete rc my-replicationcontroller-1
echo "-- What remained in my-project-1 --"
oc get all

oc project my-project-2
oc label route my-route-2 key-route-label-
# Remove template parameters ("json merge" mode completely replaces arrays)
oc patch --type=merge template my-template-2 --patch='{"parameters": []}'
oc delete pod my-pod-2


while oc get --show-all projects | grep my-project-0; do
  echo "... waiting for my-project-0 to disappear ..."
  sleep 3
done

echo; echo "===== Record second VCR ====="

rm -v "$VCR_DIR"/refresher_after_deletions.{yml,txt} || true
describe_vcr > "$VCR_DIR"/refresher_after_deletions.txt
env RECORD_VCR=after_deletions bundle exec rspec "$SPEC" || echo "^^ FAILURES ARE POSSIBLE, YOU'LL HAVE TO EDIT THE SPEC"

echo; echo "Summaries written to .txt files near the .yml files."
