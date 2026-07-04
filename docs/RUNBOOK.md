# Runbook — Phoenix TaskApp

## Prerequisites
- AWS account + credentials configured (`aws configure`)
- Terraform >= 1.5, Ansible, `kubectl` (or SSH access to the control-plane)
- SSH key pair (`~/.ssh/id_rsa` referenced by Ansible inventory)

## Provision from Zero

```bash
# 1. Infrastructure
cd infra/terraform
terraform init
terraform apply   # 3 nodes: 1 control-plane, 2 workers, amd64

# 2. Update Ansible inventory with Terraform outputs
terraform output   # copy control_plane_public_ip / worker_public_ips
# edit infra/ansible/inventory.ini with the new IPs

# 3. Cluster bring-up
cd ../ansible
ansible-playbook -i inventory.ini install-k3s.yml
# verify: ssh into control-plane, `sudo kubectl get nodes` -> all Ready

# 4. Platform: Argo CD
ssh ubuntu@<control-plane-ip>
sudo kubectl create namespace argocd
sudo kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
sudo kubectl wait --for=condition=available --timeout=180s deployment --all -n argocd

# 5. Platform: cert-manager
sudo kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
sudo kubectl wait --for=condition=available --timeout=180s deployment --all -n cert-manager

# 6. Bootstrap the app via GitOps
kubectl apply -f gitops/application.yaml   # or apply from the control-plane
# Argo CD takes it from here: namespace, Secrets, Postgres, backend, frontend,
# migration Job, Ingress, NetworkPolicies, PDBs — all from manifests/
```

## Deploy a Change

All application changes go through git — never `kubectl apply` by hand:

```bash
git add manifests/<file>.yaml
git commit -m "description of change"
git push
# Argo CD auto-syncs within ~3 minutes (polling), or force immediately:
kubectl patch application taskapp-root -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

## Scale

```bash
# Edit manifests/taskapp.yaml, change `replicas:` under the Deployment, commit+push.
# Do not `kubectl scale` directly — Argo CD's selfHeal will revert it.
```

## Roll Back

```bash
git revert <bad-commit-sha>
git push
# Argo CD syncs the reverted state automatically.
```

## Recover From: A Dead Worker Node

```bash
kubectl get nodes                     # confirm NotReady
kubectl get pods -n taskapp -o wide   # pods on the dead node show Terminating/Unknown
# Kubernetes reschedules them automatically to remaining nodes within ~5 minutes
# (default node-monitor-grace-period). To force sooner:
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force
# To bring a node back after AWS/infra recovery:
kubectl uncordon <node-name>
```

## Recover From: A Dead Backend Pod

Kubernetes handles this automatically via the Deployment controller + liveness
probes — no manual action needed. To force it:

```bash
kubectl delete pod <backend-pod-name> -n taskapp
# Deployment immediately creates a replacement
```

## Recover From: A Bad Migration

```bash
# The migration Job is an Argo CD PreSync hook with backoffLimit: 3.
# If it fails repeatedly, check why:
kubectl logs -l job-name=backend-migrate -n taskapp --tail=50
# Common cause: NetworkPolicy blocking the Job pod's egress — confirm it carries
# the `app: backend` label (required by allow-backend-to-postgres/allow-egress-backend).
# Fix the manifest, commit, push; Argo CD's BeforeHookCreation policy deletes
# the failed Job and reruns it on the next sync.
```

## Known Operational Notes

- **Memory headroom**: control-plane runs on `t3.small` (2GB RAM) alongside k3s
  server, Argo CD, and cert-manager. Under sustained load this can approach full
  utilization; a `t3.medium` is recommended for anything beyond lab use (see COST.md).
- **NetworkPolicy default-deny**: any new pod added to the `taskapp` namespace
  needs an explicit Ingress AND Egress allow rule in `manifests/advanced-hardening.yaml`,
  or it will be silently blocked from all network traffic, including DNS.
