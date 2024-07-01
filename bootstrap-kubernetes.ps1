# Config
$CLUSTER_NAME = "reynardsec-cluster"
$CONTROL_PLANE_NAME = "control-plane"
$WORKER_NAMES = @("worker1", "worker2")

# Check dependencies
function Check-Command {
    param (
        [string]$Command
    )
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Host "[error] $Command is not installed on your system."
        Write-Host "Please install $Command to continue."
        exit
    }
}

Check-Command -Command "multipass"
Check-Command -Command "kubectl"

Write-Host "Welcome to the ReynardSec Test Kubernetes Cluster installer."
Write-Host "This software is distributed without any warranty."
Write-Host ""

$answer = Read-Host "Please do not use this setup for any reason on production! Okay [y/n]?"
switch ($answer.Substring(0, 1)) {
    "y" { Write-Host "Creating VMs..." }
    default { Write-Host "Aborting."; exit }
}

# Create control plane and worker VMs
multipass launch 20.04 --name $CONTROL_PLANE_NAME --cpus 2 --memory 3G --disk 20G
foreach ($WORKER in $WORKER_NAMES) {
    multipass launch 20.04 --name $WORKER --cpus 1 --memory 2G --disk 15G
}

Start-Sleep -Seconds 5

multipass list

# Configure static IP
function Configure-StaticIP {
    param (
        [string]$vmName,
        [string]$nameserver1
    )

    $currentIP = multipass exec $vmName -- bash -c "hostname -I | cut -d' ' -f1"
    $currentGateway = multipass exec $vmName -- bash -c "ip route | grep default | cut -d' ' -f3"
    if ($currentIP -and $currentGateway) {
        $currentIPWithPrefix = $currentIP + "/16"
        $netplanConfig = @"
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      dhcp6: no
      addresses:
        - $currentIPWithPrefix
      routes:
        - to: default
          via: $currentGateway
      nameservers:
        addresses:
          - $nameserver1
"@
        multipass exec $vmName -- bash -c "echo '$netplanConfig' | sudo tee /etc/netplan/01-netcfg.yaml && sudo chmod 600 /etc/netplan/01-netcfg.yaml && sudo netplan apply"
    } else {
        Write-Host "[error] Failed to retrieve IP address or gateway for $vmName."
        exit
    }
}

Configure-StaticIP -VMName $CONTROL_PLANE_NAME -Nameserver "1.1.1.1"
foreach ($WORKER in $WORKER_NAMES) {
    Configure-StaticIP -VMName $WORKER -Nameserver "1.1.1.1"
}

Start-Sleep -Seconds 5
multipass list

# Install Kubernetes tools on VMs
function Install-K8s-Tools {
    param (
        [string]$VM
    )
    Write-Host "Installing Kubernetes tools & settings on $VM..."

    multipass exec $VM -- bash -c 'sudo swapoff -a'
    multipass exec $VM -- bash -c 'echo "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/containerd.conf'
    multipass exec $VM -- bash -c 'sudo modprobe br_netfilter'
    multipass exec $VM -- bash -c 'sudo modprobe overlay'
    multipass exec $VM -- bash -c "echo net.bridge.bridge-nf-call-iptables  = 1 | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf"
    multipass exec $VM -- bash -c "echo net.ipv4.ip_forward = 1 | sudo tee -a /etc/sysctl.d/99-kubernetes-cri.conf"
    multipass exec $VM -- bash -c "echo net.bridge.bridge-nf-call-ip6tables = 1 | sudo tee -a /etc/sysctl.d/99-kubernetes-cri.conf"
    multipass exec $VM -- bash -c 'sudo sysctl --system'
    multipass exec $VM -- bash -c 'sudo apt-get update'
    multipass exec $VM -- bash -c 'sudo apt-get install -y containerd'
    multipass exec $VM -- bash -c 'sudo mkdir -p /etc/containerd'
    multipass exec $VM -- bash -c 'sudo containerd config default | sudo tee /etc/containerd/config.toml'
    multipass exec $VM -- bash -c 'sudo systemctl restart containerd'
    multipass exec $VM -- bash -c "echo deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ / | sudo tee /etc/apt/sources.list.d/kubernetes.list"
    multipass exec $VM -- bash -c 'sudo mkdir -p /etc/apt/keyrings'
    multipass exec $VM -- bash -c 'curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg'
    multipass exec $VM -- bash -c 'sudo apt-get update'
    multipass exec $VM -- bash -c 'sudo apt-get install -y kubelet=1.30.1-1.1 kubeadm=1.30.1-1.1 kubectl=1.30.1-1.1'
    multipass exec $VM -- bash -c 'sudo apt-mark hold kubelet kubeadm kubectl'
    multipass exec $VM -- bash -c 'sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock'
    multipass exec $VM -- bash -c 'sudo systemctl daemon-reload'
    multipass exec $VM -- bash -c 'sudo systemctl restart kubelet'
}

Install-K8s-Tools -VM $CONTROL_PLANE_NAME
foreach ($WORKER in $WORKER_NAMES) {
    Install-K8s-Tools -VM $WORKER
}

Write-Host "Initializing Kubernetes cluster on control-plane..."

$current_ip = multipass exec $CONTROL_PLANE_NAME -- bash -c "hostname -I | cut -d' ' -f1"
$current_ip = $current_ip.Split("/")[0]

$kubeadmConfig = @"
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable-1.30
controlPlaneEndpoint: '$current_ip:6443'
networking:
  podSubnet: '10.244.0.0/16'
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: '$current_ip'
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    node-ip: '$current_ip'
"@

multipass exec $CONTROL_PLANE_NAME -- bash -c "echo '$kubeadmConfig' | sudo tee /home/ubuntu/kubeadm-config.yaml"
multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo kubeadm init --config=/home/ubuntu/kubeadm-config.yaml'
multipass exec $CONTROL_PLANE_NAME -- bash -c 'mkdir -p ~/.kube'
multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config'
multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo chown $(id -u):$(id -g) ~/.kube/config'

if (-Not (Test-Path "$HOME/.kube")) {
    mkdir "$HOME/.kube"
}

multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo cat /etc/kubernetes/admin.conf' > "$HOME/.kube/config-$CLUSTER_NAME"

$CONFIG_FILE = "$HOME/.kube/config-$CLUSTER_NAME"
(Get-Content $CONFIG_FILE).replace("kubernetes-admin@kubernetes", $CLUSTER_NAME) | Set-Content -Path $CONFIG_FILE

$env:KUBECONFIG = $CONFIG_FILE

kubectl config get-contexts
kubectl config use-context $CLUSTER_NAME

Write-Host "Installing Calico network plugin..."
multipass exec $CONTROL_PLANE_NAME -- bash -c 'kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml'
Start-Sleep -Seconds 30

Write-Host "Waiting for control-plane node to become Ready..."
while ($true) {
    if (kubectl get nodes | Select-String -Pattern "control-plane" | Select-String -Pattern "NotReady") {
        Write-Host "Waiting for control-plane node to become Ready..."
        Start-Sleep -Seconds 5
    } else {
        Write-Host "Success, control-plane is now in Ready state."
        break
    }
}

$JOIN_CMD = multipass exec $CONTROL_PLANE_NAME -- bash -c 'kubeadm token create --print-join-command'

foreach ($WORKER in $WORKER_NAMES) {
    Write-Host "Joining $WORKER to the Kubernetes cluster..."
    multipass exec $WORKER -- bash -c "sudo $JOIN_CMD"
    Start-Sleep -Seconds 3
}

Write-Host "Install additional tools and configs..."

Start-Sleep -Seconds 10

multipass exec $CONTROL_PLANE_NAME -- bash -c 'sudo apt -y install etcd-client jq golang-go docker.io vsftpd make'
multipass exec $CONTROL_PLANE_NAME -- bash -c "echo 'anonymous_enable=YES' | sudo tee -a /etc/vsftpd.conf && sudo systemctl restart vsftpd.service"

Write-Host "Waiting for control-plane node to become Ready..."
Start-Sleep -Seconds 10
while ($true) {
    if (kubectl get nodes | Select-String -Pattern "control-plane" | Select-String -Pattern "NotReady") {
        Write-Host "Waiting for control-plane node to become Ready..."
        Start-Sleep -Seconds 5
    } else {
        Write-Host "Success, control-plane is now in Ready state."
        break
    }
}

function Check-And-Execute {
    param (
        [string]$CommandToExecute
    )
    while ($true) {
        $ready = kubectl get nodes | Select-String -Pattern "control-plane" | ForEach-Object { $_ -split " " } | Select-Object -Skip 1
        if ($ready -eq "Ready") {
            if ($CommandToExecute) {
                Invoke-Expression $CommandToExecute
            }
            break
        } else {
            Write-Host "Control-plane is not ready yet. Waiting..."
            Start-Sleep -Seconds 5
        }
    }
}

Check-And-Execute -CommandToExecute "kubectl run default-nginx --image=nginx"
Check-And-Execute -CommandToExecute "kubectl apply -f allow-anonymous.yaml"
Check-And-Execute -CommandToExecute "kubectl create namespace team1"
Check-And-Execute -CommandToExecute "kubectl create namespace team2"
Check-And-Execute -CommandToExecute "kubectl apply -f bob-external.yaml"
Check-And-Execute -CommandToExecute "kubectl certificate approve bob-external"
Check-And-Execute -CommandToExecute "kubectl create role role-bob-external --verb=create --verb=get --verb=list --verb=update --verb=delete --resource=pod"
Check-And-Execute -CommandToExecute "kubectl create rolebinding rolebinding-bob-external --role=role-bob-external --user=bob-external"
Check-And-Execute -CommandToExecute "kubectl apply -f namespaces-and-segmentation.yaml"
Check-And-Execute -CommandToExecute "kubectl apply -f external-contractor.yaml"
kubectl get csr -o name | ForEach-Object { kubectl certificate approve $_ }

multipass exec control-plane -- bash -c "sudo sed -i '/- kube-apiserver/a \    - --anonymous-auth=true' /etc/kubernetes/manifests/kube-apiserver.yaml"

Write-Host "Waiting for control-plane node to become Ready..."
Start-Sleep -Seconds 5
while ($true) {
    if (kubectl get nodes | Select-String -Pattern "control-plane" | Select-String -Pattern "NotReady") {
        Write-Host "Waiting for control-plane node to become Ready..."
        Start-Sleep -Seconds 5
    } else {
        Write-Host "Success, control-plane is now in Ready state."
        break
    }
}

if (-not (Test-Path "$HOME/.kube/config")) {
    Copy-Item -Path $CONFIG_FILE -Destination "$HOME/.kube/config"
} else {
    Write-Host "Existing kube config detected."
    $merge_choice = Read-Host "Do you want to merge the new configuration with the existing one? [y/n]"
    if ($merge_choice -eq "y" -or $merge_choice -eq "Y") {
        Copy-Item -Path "$HOME/.kube/config" -Destination "$HOME/.kube/config-backup-by-reynardsec"
        $mergedConfig = kubectl config view --flatten --kubeconfig "$CONFIG_FILE;$HOME/.kube/config"
        $mergedConfig | Set-Content -Path "$HOME/.kube/config"
    }
    kubectl config get-contexts
    kubectl config use-context $CLUSTER_NAME
    Write-Host "Context switched to $CLUSTER_NAME."
}

Write-Host "Done. Your cluster-info:"
Check-And-Execute -CommandToExecute "kubectl cluster-info"
Write-Host "and nodes:"
Check-And-Execute -CommandToExecute "kubectl get nodes"
