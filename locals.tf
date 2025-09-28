locals {
    # Cloud init bootstrap script.
    cloud_init = <<-EOT
    #cloud-config
    package_update: true
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
      - containerd
    runcmd:
      - swapoff -a
      - sed -i '/ swap / s/^/#/' /etc/fstab

      - modprobe overlay
      - modprobe br_netfilter
      - tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

      - tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
      - sysctl --system

      - mkdir -p /etc/containerd
      - containerd config default | tee /etc/containerd/config.toml
      - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      - systemctl restart containerd
      - systemctl enable containerd

      - mkdir -p /etc/apt/keyrings
      - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
      - apt-get update
      - apt-get install -y kubelet kubeadm kubectl
      - apt-mark hold kubelet kubeadm kubectl
  EOT

  # Static-key maps -> keys known at plan time
  master_ip_map = {
    for idx in range(var.servers["master"].count) :
    "master-${idx}" => scaleway_instance_server.master[idx].public_ip
  }

  worker_ip_map = {
    for idx in range(var.servers["worker"].count) :
    "worker-${idx}" => scaleway_instance_server.workers[idx].public_ip
  }

  ip_map = merge(local.master_ip_map, local.worker_ip_map)

  # Keep your existing inventory rendering
  master_public_ips = [for s in scaleway_instance_server.master  : s.public_ip]
  worker_public_ips = [for s in scaleway_instance_server.workers : s.public_ip]
  inventory_content = templatefile("${path.module}/hosts.tmpl", {
    master_ips                   = local.master_public_ips
    worker_ips                   = local.worker_public_ips
    ansible_user                 = var.ansible_user
    ansible_ssh_private_key_file = var.ansible_ssh_private_key_file
  })

  ansible_extra_args = join(" ", [for k, v in var.ansible_extra_vars : "-e '${k}=${v}'"])
}
