#!/bin/bash

# =============================================================
# Kubernetes Worker节点安装脚本
# =============================================================

set -e

# 配置参数（根据Master节点安装时设置）
KUBERNETES_VERSION="v1.34.1"
CONTAINERD_VERSION="2.1.4"
CNI_PLUGINS_VERSION="v1.8.0"
CRICTL_VERSION="v3.30.4"
REGISTRY_MIRROR="registry.aliyuncs.com/google_containers"
SANDBOX_IMAGE="registry.aliyuncs.com/google_containers"
WORKER_HOSTNAME_PREFIX="k8s-worker"
MASTER_HOSTNAME="k8s-master"
MASTER_IP="192.168.30.112"

# 生成worker主机名
worker_index=112
WORKER_HOSTNAME="k8s-worker-"
hostnamectl set-hostname 

echo "============================================================="
echo "安装 Kubernetes Worker节点"
echo "主机名: $(hostname)"
echo "K8s版本: ${KUBERNETES_VERSION}"
echo "连接Master: ${MASTER_IP} (${MASTER_HOSTNAME})"
echo "============================================================="

# ==============================
# Step 1: 系统预配置
# ==============================
if [ "$1" != "step2" ]; then
  echo "启动Worker安装流程 Step 1/2"
  sleep 2

  # 添加master主机解析
  if ! grep -q "${MASTER_HOSTNAME}" /etc/hosts; then
    echo "${MASTER_IP} ${MASTER_HOSTNAME}" >> /etc/hosts
  fi

  # 开启IPv4转发
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null

  # 关闭swap
  swapoff -a
  if grep -q swap /etc/fstab; then
    sed -i '/swap/s/^/#/' /etc/fstab
  fi

  # 禁用SELinux与防火墙
  setenforce 0
  if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  fi
  systemctl disable --now firewalld

  echo "==========================================================="
  echo "Worker Step 1 完成！请执行以下操作："
  echo "1. 手动重新打开终端"
  echo "2. 新终端使用以下命令加入集群:"
  echo "   $ ./install-k8s-worker.sh step2 \"<JOIN_COMMAND>\""
  echo "  <JOIN_COMMAND> 替换为Master提供的kubeadm join命令"
  echo "==========================================================="
  
  exit 0
fi

# ==============================
# Step 2: K8s组件安装并加入集群
# ==============================

if [ -z "$2" ]; then
  echo "错误：未提供kubeadm join命令!"
  echo "使用方法: ./install-k8s-worker.sh step2 \"<kubeadm join命令>\""
  exit 1
fi

JOIN_COMMAND="$2"

echo "启动Worker安装流程 Step 2/2"
sleep 2

# 验证内核版本
echo "[系统内核] 当前内核版本：$(uname -r)"

# 安装 containerd
echo "[容器运行时] 安装containerd 2.1.4"
CONTAINERD_TARBALL="containerd-2.1.4-linux-amd64.tar.gz"
# 检查 containerd 是否已安装
if ! command -v /usr/local/bin/containerd &> /dev/null; then
  if [ ! -f "containerd-2.1.4-linux-amd64.tar.gz" ]; then
    curl -sL -O https://github.com/containerd/containerd/releases/download/v2.1.4/containerd-2.1.4-linux-amd64.tar.gz
  fi
  tar Cxzvf /usr/local containerd-2.1.4-linux-amd64.tar.gz >/dev/null
else
  echo "containerd 已安装，跳过。"
fi

# 检查 systemd 配置是否已存在
if [ ! -f "/etc/systemd/system/containerd.service" ]; then
  curl -s -o /etc/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
fi

# 检查 runc 是否已安装
RUNC_BINARY="runc.amd64"
if ! command -v /usr/local/sbin/runc &> /dev/null; then
  if [ ! -f "runc.amd64" ]; then
    curl -sL -O https://github.com/opencontainers/runc/releases/download/v1.3.2/runc.amd64
  fi
  install -m 755 runc.amd64 /usr/local/sbin/runc
else
  echo "runc 已安装，跳过。"
fi

# 安装 CNI 插件
echo "[网络插件] 安装CNI v1.8.0"
CNI_TARBALL="cni-plugins-linux-amd64-v1.8.0.tgz"
if [ ! -d "/opt/cni/bin" ] || [ ! "bandwidth
bridge
dhcp
dummy
firewall
host-device
host-local
ipvlan
LICENSE
loopback
macvlan
portmap
ptp
README.md
sbr
static
tap
tuning
vlan
vrf" ]; then
  if [ ! -f "cni-plugins-linux-amd64-v1.8.0.tgz" ]; then
    curl -sL -O https://github.com/containernetworking/plugins/releases/download/v1.8.0/cni-plugins-linux-amd64-v1.8.0.tgz
  fi
  mkdir -p /opt/cni/bin
  tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.8.0.tgz >/dev/null
else
  echo "CNI 插件已安装，跳过。"
fi

# 配置containerd
if [ ! -d "/etc/containerd/" ] || [ ! -f "/etc/containerd/config.toml" ]; then
  mkdir -p /etc/containerd/
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  sed -i "s|sandbox = 'registry.k8s.io/pause:3.10'|sandbox = \"registry.aliyuncs.com/google_containers/pause:3.10\"|g" /etc/containerd/config.toml
  sed -i "/ShimCgroup = ''/a\            SystemdCgroup = true" /etc/containerd/config.toml
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
else
  echo "containerd 已配置，跳过。"
fi

# 安装Kubernetes
echo "[Kubernetes] 安装组件 v1.34.1"
YUMKUBERNETES_VERSION=v1.34
cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
yum install -y kubelet kubeadm --disableexcludes=kubernetes
systemctl enable --now kubelet

# 加入集群
echo "[加入集群] 正在加入Kubernetes集群..."
eval $JOIN_COMMAND

# calico镜像下载
ctr -n k8s.io image pull quay.io/calico/cni:v3.30.4
ctr -n k8s.io image pull quay.io/calico/node:v3.30.4
ctr -n k8s.io image pull quay.io/calico/kube-controllers:v3.30.4

# 配置crictl
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "==========================================================="
echo "Worker节点加入完成！"
echo "可在Master节点执行以下命令查看节点状态:"
echo "   kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf"
echo "==========================================================="
