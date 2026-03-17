#! /bin/sh

# Requirements:
# 1. need a PV or PVC mounted at: /bazel-out-lower
# 2. need a emptyDir volume mounted at: /bazel-out-overlay
# 3. need an emptyDir volume mounted at: /home/jenkins/.tidb
# 4.1 (optional) mount downward api volume to /etc/containerinfo:
#    volumes:
#    - name: containerinfo
#      downwardAPI:
#        items:
#          - path: cpu_limit
#            resourceFieldRef:
#              containerName: ...
#              resource: limits.cpu
#          - path: cpu_request
#            resourceFieldRef:
#              containerName: ...
#              resource: requests.cpu
#          - path: mem_limit
#            resourceFieldRef:
#              containerName: ...
#              resource: limits.memory
#          - path: mem_request
#            resourceFieldRef:
#              containerName: ...
#              resource: requests.memory
# 4.2 (optional) need a PV or PVC mounted at /share/.cache/bazel-repository-cache with `ReadWriteMany`` mode.

if which bazel; then
    echo "has bazel tool."
else
    echo "no bazel bin found, skip."
    exit 0
fi

mkdir -p /home/jenkins/.tidb/tmp 2>/dev/null || true

# generate file $HOME/.bazelrc
# ref: https://docs.bazel.build/versions/5.3.1/user-manual.html
:> ~/.bazelrc

# fix bazel OOM in container.
if [ -d /etc/containerinfo ]; then
    cpu_limit=$(cat /etc/containerinfo/cpu_limit 2>/dev/null)
    mem_limit=$(cat /etc/containerinfo/mem_limit 2>/dev/null)
    if [ -n "$cpu_limit" ] && [ -n "$mem_limit" ]; then
        mem_limit=$(((mem_limit / 1048576) * 9 / 10 ))
        # Use $var (not ${var}) to avoid Flux postBuild substitution stripping values.
        echo "build --local_ram_resources=$mem_limit --local_cpu_resources=$cpu_limit --jobs=$cpu_limit" >> ~/.bazelrc
    fi
fi
