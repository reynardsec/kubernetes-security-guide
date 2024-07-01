#!/bin/bash

# Config
CLUSTER_NAME="reynardsec-cluster"
CONTROL_PLANE_NAME="control-plane"
WORKER_NAMES=("worker1" "worker2")

# Check dependencies
check_command() {
    if ! command -v $1 &> /dev/null
    then
        echo "[error] $1 is not installed on your system."
        echo "Please install $1 to continue."
        exit
    fi
}

check_command multipass
check_command kubectl

echo "Welcome to the ReynardSec Test Kubernetes Cluster installer."
echo "This software is distributed without any warranty."
echo ""

read -p "Please do not use this setup for any reason on production! Okay [y/n]? " answer
case ${answer:0:1} in
    y|Y )
        echo "Creating VMs..."
    ;;
    * )
        echo "Aborting."
        exit
    ;;
esac

# Create control plane and worker VMs
multipass launch 20.04 --name $CONTROL_PLANE_NAME --cpus 2 --memory 3G --disk 20G
for WORKER in "${WORKER_NAMES[@]}"; do
    multipass launch 20.04 --name $WORKER --cpus 1 --memory 2G --disk 15G
done

sleep 5

multipass list

# Configure static IP 
configure_static_ip() {
  local vm_name=$1
  local nameserver=$2

  local current_ip=$(multipass exec $vm_name -- ip addr show ens3 | grep 'inet ' | awk '{print $2}')
  local current_gateway=$(multipass exec $vm_name -- ip route | grep default | awk '{print $3}')

  multipass exec $vm_name -- bash -c "echo \"
network:
  version: 2
  ethernets:
    ens3:
      dhcp4: no
      dhcp6: no
      addresses:
        - $current_ip
      routes:
        - to: default
          via: $current_gateway
      nameservers:
        addresses:
          - $nameserver
\" | sudo tee /etc/netplan/01-netcfg.yaml && sudo chmod 600 /etc/netplan/01-netcfg.yaml && sudo netplan apply"
}

configure_static_ip $CONTROL_PLANE_NAME "1.1.1.1"
for WORKER in "${WORKER_NAMES[@]}"; do
    configure_static_ip $WORKER "1.1.1.1"
done

sleep 5
multipass list

# Install Kubernetes tools on VMs
install_k8s_tools() {
    local VM=$1
    echo "Installing Kubernetes tools & settings on $VM..."

    multipass exec $VM -- bash -c 'sudo swapoff -a'

    multipass exec $VM -- bash -c 'cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF'
    multipass exec $VM -- bash -c 'sudo modprobe br_netfilter'
    multipass exec $VM -- bash -c 'sudo modprobe overlay'

    multipass exec $VM -- bash -c 'cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF'
    multipass exec $VM -- bash -c 'sudo sysctl --system'

    multipass exec $VM -- bash -c 'sudo apt-get update'
    multipass exec $VM -- bash -c 'sudo apt-get install -y containerd'
    multipass exec $VM -- bash -c 'sudo mkdir -p /etc/containerd'
    multipass exec $VM -- bash -c 'sudo containerd config default | sudo tee /etc/containerd/config.toml'
    multipass exec $VM -- bash -c 'sudo systemctl restart containerd'

    multipass exec $VM -- bash -c 'echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list'
    multipass exec $VM -- bash -c 'sudo mkdir -p /etc/apt/keyrings'
    multipass exec $VM -- bash -c 'curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg'
    multipass exec $VM -- bash -c 'sudo apt-get update'
    multipass exec $VM -- bash -c 'sudo apt-get install -y kubelet=1.30.1-1.1 kubeadm=1.30.1-1.1 kubectl=1.30.1-1.1'
    multipass exec $VM -- bash -c 'sudo apt-mark hold kubelet kubeadm kubectl'

    multipass exec $VM -- bash -c 'sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock'

    multipass exec $VM -- bash -c 'sudo systemctl daemon-reload'
    multipass exec $VM -- bash -c 'sudo systemctl restart kubelet'
}

install_k8s_tools $CONTROL_PLANE_NAME
for WORKER in "${WORKER_NAMES[@]}"; do
    install_k8s_tools $WORKER
done

echo "Initializing Kubernetes cluster on control-plane..."

current_ip=$(multipass exec $CONTROL_PLANE_NAME -- ip addr show ens3 | grep 'inet ' | awk '{print $2}')
current_ip=$(echo "$current_ip" | sed 's#/.*##')

multipass exec $CONTROL_PLANE_NAME -- bash -c "cat <<EOF | sudo tee /home/ubuntu/kubeadm-config.yaml
# kubeadm-config.yaml

apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable-1.30
controlPlaneEndpoint: \"$current_ip:6443\"
networking:
  podSubnet: \"10.244.0.0/16\"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: \"$current_ip\"
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    node-ip: \"$current_ip\"
EOF"

multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo kubeadm init --config=/home/ubuntu/kubeadm-config.yaml'

multipass exec $CONTROL_PLANE_NAME -- bash -c 'mkdir -p ~/.kube'
multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config'
multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo chown $(id -u):$(id -g) ~/.kube/config'

mkdir -p $HOME/.kube
multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo cat /etc/kubernetes/admin.conf' > $HOME/.kube/config-$CLUSTER_NAME

CONFIG_FILE="$HOME/.kube/config-$CLUSTER_NAME"

sed -i "" "s/kubernetes-admin@kubernetes/$CLUSTER_NAME/g" $CONFIG_FILE

export KUBECONFIG=$CONFIG_FILE

echo $KUBECONFIG


kubectl config get-contexts
kubectl config use-context $CLUSTER_NAME

echo "Installing Calico network plugin..."
multipass exec $CONTROL_PLANE_NAME -- bash -c 'kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml'
sleep 30

echo "Waiting for control-plane node to become Ready..."
while true; do
    if kubectl get nodes | grep control-plane | grep -q NotReady; then
        echo "Waiting for control-plane node to become Ready..."
        sleep 5
    else
        echo "Success, control-plane is now in Ready state."
        break
    fi
done

JOIN_CMD=$(multipass exec $CONTROL_PLANE_NAME -- bash -c 'kubeadm token create --print-join-command')

for WORKER in "${WORKER_NAMES[@]}"; do
    echo "Joining $WORKER to the Kubernetes cluster..."
    multipass exec $WORKER -- bash -c "sudo $JOIN_CMD"
    sleep 3
done

echo "Install additional tools and configs..."

sleep 10

multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo apt -y install etcd-client jq golang-go docker.io vsftpd make'
multipass exec $CONTROL_PLANE_NAME -- bash -c "echo 'anonymous_enable=YES' | sudo tee -a /etc/vsftpd.conf && sudo systemctl restart vsftpd.service"

echo "Waiting for control-plane node to become Ready..."
sleep 10 
while true; do
    if kubectl get nodes | grep control-plane | grep -q NotReady; then
        echo "Waiting for control-plane node to become Ready..."
        sleep 5
    else
        echo "Success, control-plane is now in Ready state."
        break
    fi
done

check_and_execute() {
    local command_to_execute="$1"
    #echo "Checking if control-plane node is Ready..."
    while true; do
        local ready=$(kubectl get nodes | grep control-plane | awk '{print $2}')
        if [ "$ready" == "Ready" ]; then
            #echo "Control-plane is now in Ready state."
            if [ -n "$command_to_execute" ]; then
                eval "$command_to_execute"
            fi
            break
        else
            echo "Control-plane is not ready yet. Waiting..."
            sleep 5
        fi
    done
}

check_and_execute "kubectl run default-nginx --image=nginx"

check_and_execute "kubectl apply -f allow-anonymous.yaml"

check_and_execute "kubectl create namespace team1"
check_and_execute "kubectl create namespace team2"
check_and_execute "kubectl apply -f namespaces-and-segmentation.yaml"

check_and_execute "kubectl apply -f bob-external.yaml"
check_and_execute "kubectl certificate approve bob-external"
check_and_execute "kubectl create role role-bob-external --verb=create --verb=get --verb=list --verb=update --verb=delete --resource=pod"
check_and_execute "kubectl create rolebinding rolebinding-bob-external --role=role-bob-external --user=bob-external"

check_and_execute "kubectl apply -f external-contractor.yaml"

check_and_execute "kubectl get csr | grep Pending | cut -d' ' -f1 | xargs -L 1 kubectl certificate approve"

multipass exec control-plane -- bash -c "sudo sed -i '/- kube-apiserver/a \    - --anonymous-auth=true' /etc/kubernetes/manifests/kube-apiserver.yaml"

echo "Waiting for control-plane node to become Ready..."
sleep 5
while true; do
    if kubectl get nodes | grep control-plane | grep -q NotReady; then
        echo "Waiting for control-plane node to become Ready..."
        sleep 5
    else
        echo "Success, control-plane is now in Ready state."
        break
    fi
done

# Handle existing kube config
if [ ! -f "$HOME/.kube/config" ]; then
    cp $CONFIG_FILE $HOME/.kube/config
else
    echo "Existing kube config detected!"
    read -p "Do you want to merge the new configuration with the existing one? [y/n]: " merge_choice
    if [[ $merge_choice == "y" || $merge_choice == "Y" ]]; then
        backup_file="$HOME/.kube/config-backup-by-reynardsec"
        cp "$HOME/.kube/config" $backup_file
        echo "Backup of original .kube/config saved in $backup_file"
        KUBECONFIG=$CONFIG_FILE:$HOME/.kube/config kubectl config view --flatten > $HOME/.kube/merged-config
        mv $HOME/.kube/merged-config $HOME/.kube/config
    fi
    kubectl config get-contexts
    kubectl config use-context $CLUSTER_NAME
    echo "Context switched to $CLUSTER_NAME."
fi

echo "Done. Your cluster-info:"
check_and_execute "kubectl cluster-info"

echo "and nodes:"
check_and_execute "kubectl get nodes"
