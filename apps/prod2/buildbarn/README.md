# Buildbarn deployment for Kubernetes

> It is copied from the [buildbarn/bb-deployments](https://github.com/buildbarn/bb-deployments/tree/master/kubernetes) repository.

These manifests can be used to set up a full Buildbarn cluster on
Kubernetes. The cluster can be created by running the following command:

```sh
kubectl apply -k .
```

These files assume that the cluster needs to be created in the
`buildbarn` namespace. Storage is backed by persistent volumes.
