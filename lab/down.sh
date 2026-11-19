#!/usr/bin/env bash
# 删除整个实验集群。
set -euo pipefail
kind delete cluster --name flux-lab
