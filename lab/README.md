# 本地 Flux 实验环境(kind)

在自己电脑上跑一个最小的集群,用来观察 Flux 怎么工作,也用来验证 #31(RBAC)之类的改动。
这个目录是个人实验用的,**不要包含在提给 ocf/flux 的 PR 里**。

## 它做了什么

| 和 prod 一样的部分 | 和 prod 不同的部分 |
|---|---|
| Flux 版本和组件:直接 apply `bootstrap/prod/flux-system/gotk-components.yaml` | 没有 `flux bootstrap`,入口是 `lab/sync.yaml` |
| GitRepository 名字叫 `cluster`,1 分钟拉一次 | 只同步 `cluster/apps/templates` 和 `cluster/apps/labmap` |
| app 的 YAML 与仓库完全一致 | 没有 cilium、rook、cert-manager(依赖真实硬件或外网 DNS) |
| | 没有 SOPS。labmap 需要的 `prometheus-secret` 用假值代替 |
| | 没有 ImageUpdateAutomation(它需要往 Git 推送的权限) |

没有 ingress 控制器,所以 Ingress 对象会创建出来,但不会有人处理它。访问服务用 `kubectl port-forward`。

## 准备工具

需要 Docker(Docker Desktop 或 OrbStack)、kind、kubectl、flux、git。

```bash
# macOS
brew install kind kubectl fluxcd/tap/flux

# 或者用 nix
nix shell nixpkgs#kind nixpkgs#kubectl nixpkgs#fluxcd
```

## 启动与删除

```bash
./lab/up.sh                                # 拉取当前仓库 origin 的当前分支
BRANCH=main ./lab/up.sh                    # 指定分支
GITHUB_TOKEN=xxx ./lab/up.sh               # fork 是私有仓库时(只需 read 权限)
./lab/down.sh                              # 删除整个集群
```

`up.sh` 可以重复执行。Flux 读的是 GitHub 上的分支,**本地改动必须先 push 才会生效**。

## 练习 1:看清楚 Flux 装了什么

```bash
kubectl get pods -n flux-system            # 6 个控制器
kubectl get crds | grep fluxcd             # Flux 新增的资源类型
kubectl get gitrepository,kustomization -n flux-system
```

## 练习 2:跟踪一次改动

1. 把 `cluster/apps/templates/deployment.yaml` 的 `replicas` 改成 2,commit 并 push。
2. 分别观察每一步:

```bash
flux get sources git --watch               # revision 变成新 commit:source-controller 拉到了
flux get kustomizations --watch            # lab-templates 重新 Ready:kustomize-controller 已 apply
kubectl get events -n templates --watch    # ReplicaSet 扩容、调度、拉镜像:k8s 自带的控制器
```

不想等 1 分钟,可以手动触发:`flux reconcile kustomization lab-templates --with-source`。

## 练习 3:Flux 会把手动改动改回去

```bash
kubectl -n templates scale deploy templates --replicas=5
flux reconcile kustomization lab-templates
kubectl -n templates get deploy templates  # 又回到 Git 里的值
```

然后试试从 Git 里删掉 `service.yaml` 并 push,观察 `prune: true` 把 Service 删除。

## 练习 4:镜像自动更新的前半段

```bash
flux get images repository -A              # image-reflector-controller 从 ghcr.io 读到的 tag
flux get images policy -A                  # ImagePolicy 选出的最新 digest
```

拿这里的 digest 和 `deployment.yaml` 里注释 `# {"$imagepolicy": ...}` 所在行的 digest 对比。prod 里由 ImageUpdateAutomation 把新 digest 写回 Git。

## 练习 5:确认 #31 的问题(现在 app 目录有 cluster-admin 权限)

1. 在 `cluster/apps/templates/` 新建 `attack.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lab-attack
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: default
  namespace: templates
```

2. push 之后执行 `kubectl get clusterrolebinding lab-attack`。它会被创建成功,也就是说,任何能往 app 目录提交 YAML 的人,都能把任意身份提升成 cluster-admin。
3. 查看 Flux 是以什么身份 apply 的:

```bash
kubectl auth can-i '*' '*' --as=system:serviceaccount:flux-system:kustomize-controller   # yes
```

做完 #31 之后再跑一次这个练习,预期结果是 Kustomization 报 `forbidden`,而 `lab-attack` 不会出现。
**练习完记得删除 attack.yaml,不要把它 push 到要提 PR 的分支。**

## 出问题时看哪里

```bash
flux get all -A                                         # 哪个对象没 Ready
kubectl describe kustomization lab-labmap -n flux-system # 看 Conditions 和 Events
flux logs --level=error                                 # 所有 Flux 控制器的错误日志
flux tree kustomization lab-labmap                      # 这个 Kustomization 管理了哪些对象
```

常见问题:

- `GitRepository` 报认证失败:fork 是私有仓库,设置 `GITHUB_TOKEN` 后重新执行 `up.sh`。
- Pod 一直 `ImagePullBackOff`:Docker 所在机器访问不了 ghcr.io,检查网络或代理。
- labmap 后端如果 `/health` 失败:它依赖 prometheus 的凭据,这里只是假值,Pod 不 Ready 属于预期情况,不影响练习。
