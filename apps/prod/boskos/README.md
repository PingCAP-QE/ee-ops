This overlay creates a fairly simple Boskos deployment in the namespace `apps`.

It manages the following ficticious resources:
- `mac-machine` (cleaned by the mac-machine janitor)

Beyond the core Boskos server, the following components are installed:
- The `cleaner`, to clean up automatic resources.
- The `janitor`, to clean up `mac-machine` projects.
- The `reaper`, to clean up orphaned leases

To try out this example, you will need to [install Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize). (The version of Kustomize included in Kubectl is too old at time of writing.)
Additionally, to play with this example locally, you can first create a [kind cluster](https://kind.sigs.k8s.io/).

Build the manifests:
```console
# From within this directory
$ kustomize build deployments/overlays/example/
```

Apply to a cluster:
```console
$ kustomize build . | kubectl apply -f-
```
