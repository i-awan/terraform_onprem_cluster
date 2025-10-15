variable "ansible_inventory_path" {
  description = "Where to write the generated Ansible inventory"
  type        = string
  default     = "./hosts.ini"
}

variable "ansible_playbook_path" {
  description = "Path to the Ansible playbook to run"
  type        = string
  default     = "./site.yaml"
}

variable "ansible_user" {
  description = "Remote SSH user for Ansible"
  type        = string
  default     = "ubuntu"
}

variable "ansible_ssh_private_key_file" {
  description = "Path to the SSH private key Ansible should use"
  type        = string
  default     = "~/.ssh/id_rsa" # prefer absolute path if possible
}

variable "run_ansible" {
  description = "Whether to run Ansible automatically after provisioning"
  type        = bool
  default     = true
}

variable "ansible_extra_vars" {
  description = "Extra vars to pass to ansible-playbook (-e key=value)"
  type        = map(string)
  default     = {}
}

# Number/shape of nodes
variable "servers" {
  description = "Server counts and types for master/worker nodes"
  type = object({
    master = object({ type = string, count = number })
    worker = object({ type = string, count = number })
  })
  default = {
    master = { type = "DEV1-M", count = 1 } # control-plane
    worker = { type = "DEV1-S", count = 2 } # workers
  }
}

# Where Terraform should save the kubeconfig it scps from the master
variable "local_kubeconfig_path" {
  description = "Local path to write kubeconfig for Terraform Helm/k8s providers"
  type        = string
  default     = "~/.kube/config"
}

# Toggle chart installs
variable "install_efk" {
  description = "Install EFK stack (Elasticsearch, Fluent Bit, Kibana)"
  type        = bool
  default     = true
}

variable "install_monitoring" {
  description = "Install Prometheus + Grafana via kube-prometheus-stack"
  type        = bool
  default     = true
}

# Grafana admin password (use 'sensitive = true' so it won't print)
variable "grafana_admin_password" {
  description = "Admin password for Grafana (kube-prometheus-stack)"
  type        = string
  sensitive   = true
  default     = "admin1234" # change me
}

variable "es_secret_name" {
  description = "K8s secret that holds the elastic user password (Elastic chart) or credentials (Bitnami)"
  type        = string
  default     = "elasticsearch-es-elastic-user"  # adjust if your name differs
}
