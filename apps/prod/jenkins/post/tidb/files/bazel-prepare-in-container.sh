#! /bin/sh

# Requirements:
# 1. need a PV or PVC mounted at: /bazel-out-lower
# 2. need a emptyDir volume mounted at: /bazel-out-overlay
# 3. need a emptyDir volume mounted at: /home/jenkins/.tidb/tmp
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

# default job max bazel memory is 8GB in tidb.
DEFAULT_BAZEL_JVM_MAX_MEM_MB=8192

if which bazel; then
    echo "has bazel tool."
else
    echo "no bazel bin found, skip."
    exit 0
fi

mkdir /bazel-out-overlay/upper /bazel-out-overlay/work
sudo mount -t overlay overlay /home/jenkins/.tidb/tmp -o lowerdir=/bazel-out-lower,upperdir=/bazel-out-overlay/upper,workdir=/bazel-out-overlay/work

# generate file $HOME/.bazelrc
# ref: https://docs.bazel.build/versions/5.3.1/user-manual.html
: >~/.bazelrc

# fix bazel OOM in container.
if [ -d /etc/containerinfo ]; then
    cpu_limit=$(cat /etc/containerinfo/cpu_limit)
    mem_limit=$(cat /etc/containerinfo/mem_limit)
    mem_limit=$(((mem_limit / 1048576) * 9 / 10))

    # evaluate with 1/2 of the maximum memory size of bazel job.
    # total: 32GB, max job mem: 8GB => 8 jobs.
    job_limit=$((mem_limit * 2 / DEFAULT_BAZEL_JVM_MAX_MEM_MB))
    job_limit=$((job_limit < cpu_limit ? job_limit : cpu_limit))
    echo "build --local_ram_resources=${mem_limit} --local_cpu_resources=${cpu_limit} --jobs=${job_limit}" >>~/.bazelrc
fi

# set repository cache: https://docs.bazel.build/versions/5.3.1/guide.html#the-repository-cache
if [ -d /share/.cache/bazel-repository-cache ]; then
    echo "build --repository_cache=/share/.cache/bazel-repository-cache" >>~/.bazelrc
fi
