#!/usr/bin/env bash

THIS_OS="$(cat /etc/os-release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')"

KUBERNETES_VERSION="v1.24.3"
CNI_VENDOR="calico"
CALICO_VERSION="v3.22.2"
CALICO_SHORT_VERSION="v3.22"
CALICO_IP_AUTODETECTION_METHOD="can-reach=192.168.8.1"
POD_SUBNET="10.0.0.0/16"
POD_GATEWAY="10.0.0.1"
SERVICE_SUBNET="10.1.0.0/16"
KUBEOVN_VERSION="v1.10.7"


echo "Pull Kubernetes container images"
kubeadm config images pull --kubernetes-version ${KUBERNETES_VERSION}

echo "Install nerdctl"
wget https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz -O /tmp/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz
tar Cxzvvf /usr/local/bin /tmp/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz

/usr/local/bin/nerdctl version

if [[ "$CNI_VENDOR" == "calico" ]]; then
  /usr/local/bin/nerdctl -n k8s.io pull docker.io/calico/cni:${CALICO_VERSION}
  /usr/local/bin/nerdctl -n k8s.io pull docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}
  /usr/local/bin/nerdctl -n k8s.io pull docker.io/calico/node:${CALICO_VERSION}
  /usr/local/bin/nerdctl -n k8s.io pull docker.io/calico/kube-controllers:${CALICO_VERSION}
  /usr/local/bin/nerdctl -n k8s.io pull docker.io/calico/apiserver:${CALICO_VERSION}
fi

if [[ "$CNI_VENDOR" == "kube-ovn" ]]; then
  /usr/local/bin/nerdctl -n k8s.io pull docker.io/kubeovn/kube-ovn:${KUBEOVN_VERSION}
fi

echo "Init Kubernetes cluster"

cat <<EOF | tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
---
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta3
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  podSubnet: "${POD_SUBNET}"
  serviceSubnet: "${SERVICE_SUBNET}"
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF

kubeadm init --upload-certs --config kubeadm-config.yaml

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

export KUBECONFIG="/etc/kubernetes/admin.conf"

kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

if [[ "$CNI_VENDOR" == "calico" ]]; then

  # Enable Calico as CNI
  kubectl apply -f https://docs.projectcalico.org/archive/${CALICO_SHORT_VERSION}/manifests/calico.yaml

  kubectl set env daemonset/calico-node -n kube-system IP_AUTODETECTION_METHOD=${CALICO_IP_AUTODETECTION_METHOD}
  kubectl set env daemonset/calico-node -n kube-system FELIX_CHAININSERTMODE=Append

  kubectl -n kube-system rollout status ds/calico-node --timeout 300s

fi

if [[ "$CNI_VENDOR" == "kube-ovn" ]]; then
   
    # Enable KubeOVN as CNI
  wget https://raw.githubusercontent.com/kubeovn/kube-ovn/release-1.10/dist/images/install.sh -O kube-ovn-install.sh

  export POD_SUBNET=${POD_SUBNET}
  export POD_GATEWAY=${POD_GATEWAY}
  export SERVICE_SUBNET=${SERVICE_SUBNET}
  export KUBEOVN_JOIN_CIDR=${KUBEOVN_JOIN_CIDR}
  
  chmod +x ./kube-ovn-install.sh
  bash ./kube-ovn-install.sh
  
  kubectl -n kube-system rollout status deployment/ovn-central --timeout 300s
  kubectl -n kube-system rollout status deployment/kube-ovn-controller --timeout 300s
  kubectl -n kube-system rollout status daemonset/kube-ovn-cni --timeout 300s

fi

