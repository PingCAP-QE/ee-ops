#!/bin/sh
# Hot-copied JENKINS_HOME may still reference the manual migration prefix (/jenkins-cbg)
# and the pre-Helm JNLP Service (jenkins-cbg:50000). JCasC configScripts alone do not
# overwrite config.xml cloud fields, which breaks K8s agent JNLP connections.
set -eu

cfg=/var/jenkins_home/config.xml
if [ ! -f "$cfg" ]; then
  echo "skip: no config.xml"
  exit 0
fi

tmp=$(mktemp)
cp "$cfg" "$tmp"

# URI prefix: manual STS used /jenkins-cbg; HTTPRoute + chart use /jenkins-pingkai.
sed 's#http://jenkins-cbg.jenkins-cbg.svc.cluster.local:8080/jenkins-cbg/#http://jenkins-cbg.jenkins-cbg.svc.cluster.local:8080/jenkins-pingkai/#g' "$tmp" > "${tmp}.1"
mv "${tmp}.1" "$tmp"

# JNLP tunnel: Helm chart exposes agent listener on jenkins-cbg-agent Service.
sed 's#<jenkinsTunnel>jenkins-cbg.jenkins-cbg.svc.cluster.local:50000</jenkinsTunnel>#<jenkinsTunnel>jenkins-cbg-agent.jenkins-cbg.svc.cluster.local:50000</jenkinsTunnel>#g' "$tmp" > "${tmp}.1"
mv "${tmp}.1" "$tmp"

if cmp -s "$cfg" "$tmp"; then
  echo "kubernetes cloud URLs already correct"
  rm -f "$tmp"
  exit 0
fi

cp "$cfg" "${cfg}.bak-hotcopy-k8s-cloud"
mv "$tmp" "$cfg"
echo "patched kubernetes cloud jenkinsUrl/jenkinsTunnel in config.xml"
