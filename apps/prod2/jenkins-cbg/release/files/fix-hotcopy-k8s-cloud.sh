#!/bin/sh
# Hot-copied JENKINS_HOME may still reference the manual migration prefix (/jenkins-cbg)
# and the pre-Helm JNLP Service (jenkins-cbg:50000). JCasC configScripts alone do not
# overwrite config.xml cloud fields, which breaks K8s agent JNLP connections.
#
# Note: init container uses readOnlyRootFilesystem; do not use mktemp (/tmp).
set -eu

cfg=/var/jenkins_home/config.xml
if [ ! -f "$cfg" ]; then
  echo "skip: no config.xml"
  exit 0
fi

tunnel='jenkins-cbg-agent.jenkins-cbg.svc.cluster.local:50000'
tmp=/var/jenkins_home/.fix-hotcopy-k8s-cloud.tmp
tmp1=/var/jenkins_home/.fix-hotcopy-k8s-cloud.tmp1

cp "$cfg" "$tmp"

# URI prefix: manual migration used /jenkins-cbg; HTTPRoute + chart use /jenkins-pingkai.
sed 's#/jenkins-cbg/#/jenkins-pingkai/#g' "$tmp" > "$tmp1"
mv "$tmp1" "$tmp"

# JNLP tunnel: Helm chart exposes agent listener on jenkins-cbg-agent Service.
for old in \
  'jenkins-cbg:50000' \
  'jenkins-cbg.jenkins-cbg.svc.cluster.local:50000' \
  'jenkins-cbg.jenkins-cbg.svc:50000'
do
  sed "s#<jenkinsTunnel>${old}</jenkinsTunnel>#<jenkinsTunnel>${tunnel}</jenkinsTunnel>#g" "$tmp" > "$tmp1"
  mv "$tmp1" "$tmp"
done

if cmp -s "$cfg" "$tmp"; then
  echo "kubernetes cloud URLs already correct"
  rm -f "$tmp" "$tmp1"
  exit 0
fi

cp "$cfg" "${cfg}.bak-hotcopy-k8s-cloud"
mv "$tmp" "$cfg"
rm -f "$tmp1"
echo "patched kubernetes cloud jenkinsUrl/jenkinsTunnel in config.xml"
