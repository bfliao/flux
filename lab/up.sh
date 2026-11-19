#!/usr/bin/env bash
# 创建本地 kind 集群,安装与 prod 相同版本的 Flux,并同步 templates 和 labmap。
#
# 可选环境变量:
#   REPO_URL      Flux 拉取的仓库(默认:当前仓库 origin 的 https 地址)
#   BRANCH        Flux 拉取的分支(默认:当前 git 分支)
#   GITHUB_TOKEN  仓库是私有时需要,只需 read 权限
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根目录
CLUSTER=flux-lab

for t in docker kind kubectl flux git; do
  command -v "$t" >/dev/null || { echo "缺少 $t,见 lab/README.md" >&2; exit 1; }
done

origin=$(git remote get-url origin)
origin=${origin/git@github.com:/https://github.com/}
REPO_URL=${REPO_URL:-${origin%.git}}
BRANCH=${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}

echo "==> 1/5 创建 kind 集群 $CLUSTER"
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "    已存在,跳过"
else
  kind create cluster --config lab/kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> 2/5 安装 Flux(直接使用仓库里 prod 的 gotk-components.yaml,版本一致)"
kubectl apply --server-side --force-conflicts -f bootstrap/prod/flux-system/gotk-components.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Available deploy --all --timeout=5m

echo "==> 3/5 准备 Git 凭据"
secret_ref=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  flux create secret git lab-git-auth --url="$REPO_URL" \
    --username=git --password="$GITHUB_TOKEN" >/dev/null
  secret_ref="secretRef: {name: lab-git-auth}"
  echo "    已创建 Secret lab-git-auth"
else
  echo "    未设置 GITHUB_TOKEN,按公开仓库处理"
fi

echo "==> 4/5 prod 里由 SOPS 提供的 Secret,这里用假值代替"
kubectl create namespace labmap --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n labmap create secret generic prometheus-secret \
  --from-literal=PLACEHOLDER=lab --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> 5/5 让 Flux 同步 $REPO_URL ($BRANCH)"
sed -e "s|__REPO_URL__|$REPO_URL|" -e "s|__BRANCH__|$BRANCH|" -e "s|__SECRET_REF__|$secret_ref|" \
  lab/sync.yaml | kubectl apply -f -
flux reconcile source git cluster --timeout=2m || true

echo
flux get sources git
flux get kustomizations
echo
echo "完成。改动需要 push 到 $BRANCH 后 Flux 才能看到。下一步见 lab/README.md。"
