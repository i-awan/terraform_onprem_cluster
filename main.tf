

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


# Helper locals (re-use your existing ones)
locals {
  master_public_ip = local.master_public_ips[0]
}

# Copy kubeconfig from master to local file so Terraform can talk to the cluster
resource "null_resource" "fetch_kubeconfig" {
  count = var.run_ansible ? 1 : 0

  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ${var.ansible_ssh_private_key_file} ${var.ansible_user}@${local.master_public_ip}:/home/${var.ansible_user}/.kube/config ${var.local_kubeconfig_path}"
  }

  depends_on = [
    null_resource.run_ansible
  ]
}


# Dynamic storage (default): Local Path Provisioner
resource "helm_release" "local_path_provisioner" {
  name             = "local-path-provisioner"
  repository       = "https://charts.containeroo.ch"
  chart            = "local-path-provisioner"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true

  # make it the default StorageClass and set a host path
  set {
    name  = "storageClass.defaultClass"
    value = "true"
  }
  set {
    name  = "nodePathMap[0].node"
    value = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
  }
  set {
    name  = "nodePathMap[0].paths[0]"
    value = "/opt/local-path-provisioner"
  }

  depends_on = [null_resource.fetch_kubeconfig]
}


# Elasticsearch (official Elastic chart; last published 8.5.1)
resource "helm_release" "elasticsearch" {
  count            = var.install_efk ? 1 : 0
  name             = "elasticsearch"
  repository       = "https://helm.elastic.co"
  chart            = "elasticsearch"
  version          = "8.5.1"
  namespace        = "logging"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [<<-YAML
    replicas: 1
    esJavaOpts: "-Xms512m -Xmx512m"
    resources:
      requests: { cpu: "200m", memory: "1Gi" }
      limits:   { cpu: "1",    memory: "2Gi" }
    volumeClaimTemplate:
      storageClassName: local-path
      accessModes: ["ReadWriteOnce"]
      resources: { requests: { storage: 10Gi } }
    esConfig:
      elasticsearch.yml: |
        xpack.security.enabled: false
        xpack.security.transport.ssl.enabled: false
        xpack.security.http.ssl.enabled: false
  YAML
  ]

  depends_on = [helm_release.local_path_provisioner]
}

# Run this BEFORE kibana release to avoid hook collisions
resource "null_resource" "preclean_kibana_hooks" {
  provisioner "local-exec" {
    command = <<-EOT
      kubectl delete cm kibana-kibana-helm-scripts -n logging  --ignore-not-found
      kubectl delete secret elasticsearch-master-certs -n logging  --ignore-not-found
    EOT
  }
  depends_on = [null_resource.fetch_kubeconfig]
}

# Kibana (official Elastic chart; 8.5.1)
resource "helm_release" "kibana" {
  count            = var.install_efk ? 1 : 0
  name             = "kibana"
  repository       = "https://helm.elastic.co"
  chart            = "kibana"
  version          = "8.5.1"
  namespace        = "logging"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [<<-YAML
    elasticsearchHosts: "http://elasticsearch-master.logging.svc.cluster.local:9200"
    kibanaConfig:
      kibana.yml: |
        xpack.security.enabled: false
        elasticsearch.ssl.verificationMode: none
    service: { type: NodePort }
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "512Mi" }
  YAML
  ]

  depends_on      = [helm_release.elasticsearch, null_resource.preclean_kibana_hooks]
}


# Fluent Bit (official Fluent repo)
resource "helm_release" "fluent_bit" {
  count            = var.install_efk ? 1 : 0
  name             = "fluent-bit"
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  namespace        = "logging"
  create_namespace = true
  wait             = true

  values = [<<-YAML
    backend:
      type: es
      es:
        host: elasticsearch-master.logging.svc.cluster.local
        port: 9200
        index: "kubernetes"
        logstash_format: true
  YAML
  ]

  depends_on = [helm_release.elasticsearch]
}



# --- Prometheus + Grafana -----------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  count            = var.install_monitoring ? 1 : 0
  name             = "kube-prom-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true

  values = [<<-YAML
    grafana:
      adminPassword: "${var.grafana_admin_password}"
      service: { type: NodePort }
    prometheus:
      service: { type: NodePort }
    alertmanager:
      service: { type: ClusterIP }
  YAML
  ]

  depends_on = [null_resource.fetch_kubeconfig]
}
