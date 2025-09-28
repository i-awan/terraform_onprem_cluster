terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "2.42.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "scaleway" {
  zone   = "fr-par-1"
  region = "fr-par"
}

# --- Private Network ---
resource "scaleway_vpc_private_network" "k8s_net" {
  name   = "k8s-private-net"
  region = "fr-par"
}

# --- Master Node ---
resource "scaleway_instance_server" "master" {
  count = var.servers["master"].count
  name  = "k8s-master-${count.index}"

  type  = var.servers["master"].type
  image = "ubuntu_jammy"
  zone  = "fr-par-1"

  root_volume {
    size_in_gb = 20
  }

  tags = ["k8s", "master"]

  enable_dynamic_ip = true   # auto-assign public IP

  private_network {
    pn_id = scaleway_vpc_private_network.k8s_net.id
  }

  cloud_init = local.cloud_init
}

# --- Worker Nodes ---
resource "scaleway_instance_server" "workers" {
  count = var.servers["worker"].count
  name  = "k8s-worker-${count.index}"

  type  = var.servers["worker"].type
  image = "ubuntu_jammy"
  zone  = "fr-par-1"

  root_volume {
    size_in_gb = 20
  }

  tags = ["k8s", "worker"]

  enable_dynamic_ip = true   # auto-assign public IP

  private_network {
    pn_id = scaleway_vpc_private_network.k8s_net.id
  }

  cloud_init = local.cloud_init
}

# --- Outputs ---
output "master_public_ips" {
  value = [for s in scaleway_instance_server.master : s.public_ip]
}

output "worker_public_ips" {
  value = [for s in scaleway_instance_server.workers : s.public_ip]
}


# Run ansible 

# Write inventory file locally
resource "local_file" "ansible_inventory" {
  content  = local.inventory_content
  filename = var.ansible_inventory_path
}

# Per-IP known_hosts cleanup (safer than nuking the whole file)
resource "null_resource" "clean_known_hosts" {
  for_each = var.run_ansible ? local.ip_map : {}

  provisioner "local-exec" {
    # each.value is the IP
    command = "ssh-keygen -R ${each.value} >/dev/null 2>&1 || true"
  }

  depends_on = [
    scaleway_instance_server.master,
    scaleway_instance_server.workers
  ]
}

# Wait for SSH on each host
resource "null_resource" "wait_for_ssh" {
  for_each = var.run_ansible ? local.ip_map : {}

  provisioner "local-exec" {
    command = "until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i ${var.ansible_ssh_private_key_file} ${var.ansible_user}@${each.value} 'echo ok' >/dev/null 2>&1; do sleep 3; done"
  }

  depends_on = [
    scaleway_instance_server.master,
    scaleway_instance_server.workers,
    null_resource.clean_known_hosts
  ]
}


# ====== Run the playbook ======
resource "null_resource" "run_ansible" {
  count = var.run_ansible ? 1 : 0

  # Re-run if inventory content or playbook path changes
  triggers = {
    inventory_sha1 = sha1(local.inventory_content)
    playbook_path  = var.ansible_playbook_path
  }

  provisioner "local-exec" {
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
    command = "ansible-playbook -i ${var.ansible_inventory_path} ${var.ansible_playbook_path} --become ${local.ansible_extra_args}"
  }

  depends_on = [
    local_file.ansible_inventory,
    null_resource.wait_for_ssh
  ]
}
