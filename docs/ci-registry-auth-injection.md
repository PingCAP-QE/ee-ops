# CI 容器注册表认证自动注入方案（Kyverno）

## 1. 背景与目标

PingCAP-QE/ci 的 Jenkins 构建/测试 pod 需要在容器内访问多个 OCI 注册表：

- **OCI 产物下载**（`scripts/artifacts/download_pingcap_oci_artifact.sh`，经 oras 拉取）：`us-docker.pkg.dev/pingcap-testing-account/{hub,internal,dev}`（hub/dev 为脚本默认源，internal 用于内部组件，均可通过 env 切换）。
- **容器内 docker pull**（tiflash IT 镜像等）。
- **Pod 镜像拉取**（kubelet）：`ghcr.io/pingcap-qe/*`、`us-docker.pkg.dev/pingcap-testing-account/{internal/test,ghcr-remote,dockerhub-remote}` 等。

现状：hub/internal/dev 目前匿名可拉；**计划对 hub/internal/dev 开启认证**，且 CI pod 会被**随机调度到跨云集群**（GCP→AWS/Azure 等）。届时匿名拉取将失败，需在 pod 内与 kubelet 两侧同时具备认证。

**适用集群范围**：仅 **gcp** 与 **tencentcloud** 两个集群的 Jenkins 命名空间。**prod2 不参与 Jenkins 任务调度**（其 `jenkins-cbg` 不承载 CI pod），本次不覆盖 prod2。

**目标**：在 pod 创建时（admission 阶段）由 Kyverno 自动注入注册表认证，**PingCAP-QE/ci 仓库零改动**，现有与未来所有 job 自动覆盖。

## 2. 方案设计

两条 Kyverno 策略（可合并为一条多规则），作用于 Jenkins 命名空间内的 Pod。策略为 namespaced（`Policy`/`NamespacedMutatingPolicy`）还是 cluster 级别（`ClusterPolicy`/`MutatingPolicy`）不影响本方案，落地时按现有仓库惯例选择即可。

### Policy A：in-pod 注册表凭据注入（oras / docker CLI）

在 Pod 创建时**仅向名为 `utils` 的容器**注入：

1. `volume`：`ci-registry-auth`（引用 Secret，`items` 投影 `.dockerconfigjson` → `config.json`，只读）
2. `volumeMount`：`/var/run/ci/registry`
3. `env`：`DOCKER_CONFIG=/var/run/ci/registry`（兼容 `ORAS_DOCKER_CONFIG`）

覆盖范围：现 314 处 `download_pingcap_oci_artifact.sh` 调用 + tiflash IT 的 docker pull + 委托脚本均在 `utils` 容器内执行，因此只注入 `utils` 容器即可全覆盖；default/jnlp/golang 等其他容器不注入，减少注入面与误伤。

### Policy B：imagePullSecrets 注入（kubelet 拉 pod 镜像）

**仅当 Pod 内镜像命中目标仓库前缀时**才向该 Pod 注入 `spec.imagePullSecrets`（引用 `ci-registry-auth`，Secret 类型 `kubernetes.io/dockerconfigjson`），解决跨云拉取 GCP Artifact Registry / ghcr 镜像的认证。匹配清单即需认证的镜像前缀（如 `us-docker.pkg.dev/pingcap-testing-account/internal-test/`、`ghcr.io/pingcap-qe/` 等，见待确认 #6），未命中则不注入，避免对不使用这些镜像的 pod 无谓注入。

> 本轮范围：Policy B **暂仅在 tencentcloud 集群部署**（该集群已开启跨云 pod 调度），gcp 集群暂不注入，待 tencentcloud 验证稳定后再扩展到 gcp。

> 关键点：kubelet 拉镜像用的是 Pod 上的 `imagePullSecrets`，与 pod 内挂载的 config 无关，两者缺一不可，故需两条规则。

### Secret 设计（ExternalSecret 同步，单 Secret 双用）

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ci-registry-auth
  namespace: <jenkins-*>
type: kubernetes.io/dockerconfigjson   # 天然可被 imagePullSecrets 引用
data:
  .dockerconfigjson: '<config.json base64>'
```

- 由 **ExternalSecret** 从单一源同步：**新建独立 GCP Secret Manager secret `ci_registry_auth_dockerconfig_json`**（内容含全部目标 registry 的 auths，需覆盖 in-pod 与 imagePullSecrets 两侧，见下一条），每个 Jenkins 命名空间一份，跨集群不手工维护。
- in-pod 挂载用 `items: [{key: .dockerconfigjson, path: config.json}]` 投影即可（无需 Opaque 双份）。
- config.json 的 `auths` 需覆盖：Policy A 侧 `us-docker.pkg.dev`（hub/internal/dev）、`ghcr.io`（utils/builders/ci-jenkins）；Policy B 侧 `cr-qcloud.pingcap.net`、`cr.pingcap.net`。按 ee-ops 确认的实际清单。
- **每个 Jenkins 命名空间一份**；跨云时每个目标集群的对应命名空间也需同步（由 ExternalSecret 自动完成）。

### Kyverno 策略骨架（示意，ee-ops 定稿）

```yaml
apiVersion: policies.kyverno.io/v1   # gcp 升级后与 tencentcloud 统一；Kyverno 1.12 用 kyverno.io/v1
kind: ClusterPolicy                  # 或 NamespacedMutatingPolicy / Policy，均不影响
metadata:
  name: inject-ci-registry-auth
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: inject-registry-config-utils
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces:
                - jenkins-tidb
                - jenkins-tikv
                # ... 完整命名空间清单
      mutate:
        patchStrategicMerge:
          spec:
            volumes:
              - name: ci-registry-auth
                secret:
                  secretName: ci-registry-auth
                  items:
                    - key: .dockerconfigjson
                      path: config.json
            containers:
              - name: utils
                volumeMounts:
                  - name: ci-registry-auth
                    mountPath: /var/run/ci/registry
                    readOnly: true
                env:
                  - name: DOCKER_CONFIG
                    value: /var/run/ci/registry
    - name: inject-image-pull-secrets
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [ ...同 A... ]
              images:                # 仅命中目标镜像前缀的 pod 才注入
                - "cr-qcloud.pingcap.net/*"
                - "cr.pingcap.net/*"
      mutate:
        patchStrategicMerge:
          spec:
            imagePullSecrets:
              - name: ci-registry-auth
```

## 3. 兼容性与技术要点

- `oras`（1.x，经 go-containerregistry）与 `docker` CLI 均遵循 `DOCKER_CONFIG` 环境变量，回退 `~/.docker`。仓库内 Tekton/kaniko 已用同模式。
- 只注入 `utils` 容器，其余容器不受影响；下载/拉镜像逻辑均在 `utils` 内执行，覆盖完整。
- 与现有 30 处 `withCredentials('tidbx-docker-config')` 的 `~/.docker/config.json` 拷贝模式**无冲突**，可保留（后续清理）。
- Secret 挂载只读、`defaultMode` 建议 `0444`，非 root 容器可读；不依赖 fsGroup。
- 若 `utils` 容器已定义 `DOCKER_CONFIG`，Kyverno 需避免重复注入（patch 策略注意幂等）；Policy B 对已有 `imagePullSecrets` 的 pod 同样需幂等。

## 4. 交付物清单（ee-ops 仓库）

1. 策略两条（或一条双规则）：inject-registry-config-utils（仅 utils 容器）+ inject-image-pull-secrets（镜像匹配才注入；**本轮仅 tencentcloud**）
2. `ExternalSecret` 定义（每命名空间，单一源）+ `Secret` 落地形态确认
3. 各命名空间 Secret 同步机制（ExternalSecret + 单一源，跨集群自动同步）
4. 迁移说明：现 `tidbx-docker-config` 凭据内容 → Secret；灰度验证记录
5. gcp 集群 Kyverno 版本升级（chart 3.4.4 → 与 tencentcloud 3.8.2 对齐，统一使用 `policies.kyverno.io/v1`）

## 5. 灰度与回滚

1. 先在 **staging/测试命名空间**（如 jenkins-tidb 的少量 job）验证：手动建 pod → 检查 utils 容器 volume/env、imagePullSecrets 注入 → 跑一个真实下载 job（如 tidb `pull_integration_realcluster_test_next_gen`）。gcp 与 tencentcloud 本轮均生效 Policy A（gcp 已完成 Kyverno 升级）；Policy B 本轮仅在 tencentcloud 集群生效。
2. 确认 hub/internal/dev 认证后匿名失败、注入后成功；再逐步扩大到各命名空间，并将 Policy B 扩展到 gcp。
3. 回滚：删除策略与 Secret 即可，pod 创建即时恢复原状，不影响历史 pod。

## 6. 待 ee-ops 确认点

| # | 确认点 | 说明 |
|---|---|---|
| 1 | 各 CI 集群 Kyverno 版本/管理方式 | 已部署于 gcp（chart 3.4.4）、tencentcloud（3.8.2）、prod2（3.4.4），均 Flux HelmRelease 管理；prod2 不参与 Jenkins 调度，排除。**已升级 gcp 至 3.8.2 与 tencentcloud 对齐**，统一 `policies.kyverno.io/v1` |
| 2 | 需要注入的**命名空间完整清单** | 已确认：`jenkins-tidb`、`jenkins-tikv`、`jenkins-tiflow`、`jenkins-tiflash`、`jenkins-pd`（注：`post/ticdc` 目录实际创建 `jenkins-tiflow`）；staging/test 命名空间待定 |
| 3 | **匹配方式** | 已定：沿用现有 `kubernetes.jenkins.io/controller` label 惯例（namespaced MutatingPolicy 挂在各 jenkins-* 命名空间，天然按命名空间隔离）；Policy B 额外做镜像前缀匹配（见 #6）。策略 namespaced/cluster 级别均可 |
| 4 | **Secret 供应方式** | 已定 ExternalSecret 同步，**新建独立 GCP SM secret `ci_registry_auth_dockerconfig_json`**；确认其内容含全部目标 registry，以及 GAR 凭据形态（长期 `_json_key` vs 短期 token + 自动轮换） |
| 5 | **config.json 需覆盖的 registry host 清单** | Policy A 侧：`us-docker.pkg.dev`（hub/internal/dev）、`ghcr.io`；Policy B 侧：`cr-qcloud.pingcap.net`、`cr.pingcap.net`；nextgen 用到的 `gcr.io/us.gcr.io` 是否纳入 |
| 6 | **Policy B 镜像匹配清单** | **已确认**：`cr-qcloud.pingcap.net/`、`cr.pingcap.net/` 前缀命中即注入 `imagePullSecrets`。Policy B **本轮仅部署 tencentcloud**，gcp 待验证稳定后扩展 |
| 7 | hub/internal/dev 在目标云（AWS/Azure）的访问方式 | 公网可达 GCP AR，还是需在各云镜像副本？影响 config.json 内容与镜像地址 |
| 8 | 策略 Owner / 审批流程 | 谁 review 谁 approve |
| 9 | utils 镜像内 **oras 版本**确认（是否 ≥1.x 支持 DOCKER_CONFIG） | 若过旧需升级 utils 镜像（另行处理） |
| 10 | 是否清理现有 30 处 `withCredentials('tidbx-docker-config')` | 建议本轮保留，验证稳定后再清理 |
