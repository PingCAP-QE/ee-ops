## Upgrades

Renovate scans the HelmRelease and OCI HelmRepository manifests in this
directory using its Flux manager. During normal bot runs, stable chart updates
are proposed in one PR for the controller and runner scale set, while runner
image updates are proposed separately with both the tag and digest pinned.
PR creation does not require Dependency Dashboard approval; merging remains
manual. The rules are scoped to this directory in
[`.github/renovate.json`](../../../.github/renovate.json).

Before merging a chart upgrade, review the upstream release notes and validate
both charts with the committed values. Keep `upgrade.crds: CreateReplace` on the
controller HelmRelease so Flux upgrades the chart's CRDs along with the
controller. After reconciliation, check both HelmReleases and run a workflow
using the `EE-Group` runner group.

## References

1. [Deploying runner scale sets with Actions Runner Controller](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller#scaling-runners)
2. [Quickstart for Actions Runner Controller](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller)
3. [Supported runners and hardware resources of GitHub hosted runners](https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources)
