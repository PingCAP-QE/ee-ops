#!/usr/bin/env bash
# One-time operator script: finalize hot-copied JENKINS_HOME for GitOps + JCasC.
# See release/README.md § "K8s cloud (one-time)".
set -euo pipefail

NS=jenkins-cbg
STS=jenkins-cbg
PVC=jenkins-cbg
CM=jenkins-cbg-finalize-hotcopy-script
POD=finalize-hotcopy-jenkins-home
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${SCRIPT_DIR}/finalize-hotcopy-jenkins-home.py"

echo "INFO - scale down ${NS}/${STS}"
kubectl -n "$NS" scale "sts/${STS}" --replicas=0
kubectl -n "$NS" wait --for=delete "pod/${STS}-0" --timeout=180s 2>/dev/null || true

echo "INFO - create temporary ConfigMap ${CM}"
kubectl -n "$NS" create configmap "$CM" \
  --from-file=finalize-hotcopy-jenkins-home.py="$PY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "INFO - run finalize pod"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true
kubectl -n "$NS" run "$POD" --restart=Never \
  --image=alpine:3.24 \
  --overrides="$(cat <<EOF
{
  "spec": {
    "restartPolicy": "Never",
    "containers": [{
      "name": "finalize",
      "image": "alpine:3.24",
      "command": ["sh", "-c", "apk add --no-cache python3 >/dev/null && python3 /scripts/finalize-hotcopy-jenkins-home.py"],
      "volumeMounts": [
        {"name": "jenkins-home", "mountPath": "/var/jenkins_home"},
        {"name": "scripts", "mountPath": "/scripts", "readOnly": true}
      ]
    }],
    "volumes": [
      {"name": "jenkins-home", "persistentVolumeClaim": {"claimName": "${PVC}"}},
      {"name": "scripts", "configMap": {"name": "${CM}", "defaultMode": 493}}
    ]
  }
}
EOF
)"
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD}" --timeout=300s
kubectl -n "$NS" logs "$POD"
kubectl -n "$NS" delete pod "$POD" --wait=true
kubectl -n "$NS" delete configmap "$CM" --ignore-not-found

echo "INFO - scale up ${STS}"
kubectl -n "$NS" scale "sts/${STS}" --replicas=1
kubectl -n "$NS" rollout status "sts/${STS}" --timeout=300s

echo "INFO - verify cloud URLs and no legacy groovy"
kubectl -n "$NS" exec "${STS}-0" -c jenkins -- sh -c '
  test ! -f /var/jenkins_home/init.groovy.d/00-cbg-manual-verify.groovy
  grep -E "jenkinsUrl|jenkinsTunnel|containerCap|3299|3309" /var/jenkins_home/config.xml | head -12
  ls /var/jenkins_home/casc_configs/
'
