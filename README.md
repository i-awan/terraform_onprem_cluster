# Provision and Configuration of On-Prem Kubernetes Cluster

Spin up a **1× control-plane + 2× worker** Kubernetes cluster on **Scaleway** using **Terraform** for infra and **Ansible** for node configuration (containerd, kubeadm, Calico).  

A single `terraform apply`:
- creates VMs + private network,
- generates a dynamic `hosts.ini`,
- safely cleans `~/.ssh/known_hosts` entries for those IPs,
- waits for SSH,
- runs your Ansible playbook.

> ⚠️ You’ll incur cloud costs while servers are running. Use `terraform destroy` when done.

---

## Prerequisites
- Terraform **v1.5+**
- Ansible **v2.14+**
- `ssh`, `ssh-keygen`
-  **Scaleway** account with:
  - **Project API keys** exported locally
  - Your **SSH public key added to the correct project**

Export Scaleway creds (example):

```bash
export SCW_ACCESS_KEY="xxxx"
export SCW_SECRET_KEY="xxxx"
export SCW_DEFAULT_PROJECT_ID="xxxx"
export SCW_DEFAULT_REGION="fr-par"
```

Configure
Open variables.tf and tweak as needed. Common settings:

Number/type of nodes
```hcl
variable "servers" {
  description = "Server counts and types for master/worker nodes"
  type = object({
    master = object({ type = string, count = number })
    worker = object({ type = string, count = number })
  })
  default = {
    master = { type = "DEV1-M", count = 1 }
    worker = { type = "DEV1-S", count = 2 }
  }
}
```

Where to write inventory & which playbook to run (note that the inventory file hosts.ini is constructed at run-time by Terraform.)
```hcl
variable "ansible_inventory_path"         { default = "./hosts.ini" }
variable "ansible_playbook_path"          { default = "./playbooks/site.yml" }
```

SSH details for Ansible
```hcl
variable "ansible_user"                   { default = "ubuntu" }
variable "ansible_ssh_private_key_file"   { default = "~/.ssh/id_rsa" }
```

Whether to auto-run Ansible after provisioning
```hcl
variable "run_ansible"                    { default = true }
```

Extra -e vars for ansible-playbook (map)
```hcl
variable "ansible_extra_vars"             { default = {} }
```
If your master doesn’t reliably get a private IP, pass k8s_private_ip via ansible_extra_vars at apply time.


```bash
terraform init -upgrade

terraform apply -auto-approve \
  -var="ansible_inventory_path=$(pwd)/hosts.ini" \
  -var="ansible_playbook_path=$(pwd)/playbooks/site.yml" \
  -var="ansible_user=ubuntu" \
  -var="ansible_ssh_private_key_file=$HOME/.ssh/id_rsa" \
  -var='ansible_extra_vars={"k8s_private_ip":"172.16.4.3"}'   # optional override
```

What happens:

VMs & private network are created (Scaleway).

Terraform renders hosts.ini from hosts.tmpl.

Old host keys for those IPs are removed from ~/.ssh/known_hosts (per IP).

Terraform waits for SSH on each host.

Ansible runs playbooks/site.yml against hosts.ini.

To skip auto-Ansible for a run: add -var="run_ansible=false" and execute Ansible manually later.

Verify
SSH into the master:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@<MASTER_PUBLIC_IP>

# kubectl is configured for ubuntu and root by Ansible:
kubectl get nodes -o wide
kubectl get pods -n kube-system

kubectl create ns demo
kubectl -n demo create deployment nginx --image=nginx:1.27 --replicas=2
kubectl -n demo expose deploy nginx --port=80 --type=NodePort --name=nginx
kubectl -n demo get svc nginx
curl -I http://127.0.0.1:<NODEPORT>

```
Rebuild / Cleanup
Full clean (fresh infra):

```bash
terraform destroy -auto-approve
terraform apply  -auto-approve
```

Reset only Kubernetes (keep VMs):

```bash
ansible-playbook -i hosts.ini playbooks/reset.yml --become
ansible-playbook -i hosts.ini playbooks/site.yml  --become \
  -e k8s_private_ip=<MASTER_PRIVATE_IP>   # optional explicit override
```

Accessing the API from Your Laptop (Optional)

SSH tunnel (no cert changes):

```bash
ssh -N -L 6443:<MASTER_PRIVATE_IP>:6443 ubuntu@<MASTER_PUBLIC_IP>
```

point your local kubeconfig to the tunnel
```bash
kubectl config set-cluster kubernetes \
  --server=https://127.0.0.1:6443 \
  --kubeconfig ~/.kube/config.scaleway

KUBECONFIG=~/.kube/config.scaleway kubectl get nodes
```

Public API (add SANs + firewall):

Add the master’s public IP to the apiserver cert SANs (kubeadm v1beta3 config),

Restart kubelet (static pod reload),

Point kubeconfig at https://<PUBLIC_IP>:6443,

Restrict inbound 6443 to your IP in Scaleway Security Groups.

Troubleshooting
SSH “Permission denied (publickey)”
Ensure your key is added to the correct Scaleway project. Connect explicitly:
ssh -i ~/.ssh/id_rsa ubuntu@<IP>

Terraform: for_each needs known keys
This repo uses static-key maps (master-0, worker-0, …) so per-host tasks work. Keep those locals intact.

kubectl tries http://localhost:8080
On the master, Ansible copies /etc/kubernetes/admin.conf to ~/.kube/config for ubuntu and root. If you’re another user, copy it manually.

CoreDNS Pending / node NotReady
Ensure Calico is applied (Ansible does this; safe to re-apply):
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
Wait for calico-node DaemonSet to be Ready, then CoreDNS becomes Available.

Apiserver not starting
Use a real, non-broadcast private IP for --apiserver-advertise-address.
Inspect containers via crictl:


Copy code
```bash
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a | grep -E 'apiserver|etcd'
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock logs <container_id>
```

Security Notes:

Nodes have public IPs for SSH. Consider a Scaleway security group to restrict SSH to your IP.

Do not expose the API (6443) publicly unless you:
* Add the public IP to apiserver cert SANs,
* Lock 6443 to your IP,
* Rotate/secure kubeconfigs.
* Customization
* Change counts/types in variables.tf → var.servers.

Override paths:

```hcl
ansible_inventory_path
ansible_playbook_path
ansible_ssh_private_key_file
```