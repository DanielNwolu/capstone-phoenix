# Architecture — Phoenix TaskApp on Kubernetes

## Overview

TaskApp runs as a highly-available, GitOps-managed application on a self-provisioned
3-node k3s cluster on AWS. This document describes the node topology, network flow,
and how each Core requirement addresses a specific limitation of the previous
single-server Portainer deployment.

## Node Topology

- **1 control-plane node** (`t3.small`, amd64) — runs the k3s server, etcd, the
  Kubernetes API server, Argo CD, and cert-manager.
- **2 worker nodes** (`t3.small`, amd64) — run application workloads
  (backend, frontend, Postgres).
- All 3 nodes sit in a single custom VPC (`10.0.0.0/16`) with a single public subnet,
  provisioned entirely through Terraform with remote state.

## Request Flow

1. A browser resolves `taskapp.<control-plane-ip>.nip.io` to the control-plane's
   public IP (nip.io is a free wildcard DNS service — see "Domain choice" below).
2. Traffic hits port 443 on any node (k3s's built-in ServiceLB exposes Traefik on
   all 3 nodes).
3. **Traefik** (k3s's bundled Ingress controller) terminates TLS using a certificate
   issued by **cert-manager** via Let's Encrypt (HTTP-01 challenge), and routes to
   the `frontend-service` (ClusterIP) based on the `Ingress` host rule.
4. **nginx** (inside the frontend container) serves the built React SPA directly for
   all paths, and reverse-proxies any `/api/` request to `http://backend:5000`
   (same-origin design — see below).
5. **Flask backend** (2 replicas, spread across different nodes via
   `topologySpreadConstraints`) handles the request, authenticates via JWT, and
   talks to Postgres over the internal `postgres-service` headless Service.
6. **Postgres** runs as a single-replica `StatefulSet` backed by a `PersistentVolumeClaim`
   on the cluster's default storage class, ensuring data survives pod restarts.

## Same-Origin API Design (justification)

The frontend's nginx config proxies `/api/` to the backend Service internally,
so the browser only ever talks to one hostname (`taskapp.<ip>.nip.io`) over one
TLS certificate. This was chosen over a separate `api.<domain>` because:
- It avoids CORS configuration entirely.
- It requires only one certificate/Ingress instead of two.
- The frontend image already ships this proxy config out of the box.

## Domain Choice: nip.io

No domain was purchased for this capstone. `nip.io` is used instead — a free,
zero-registration wildcard DNS service that resolves `<anything>.<ip>.nip.io`
back to `<ip>`. Let's Encrypt issues a real, publicly-trusted certificate for
nip.io hostnames via the standard HTTP-01 challenge, satisfying the "valid public
certificate, not self-signed" requirement without needing a registrar. Root domain
ownership isn't checked by Let's Encrypt's HTTP-01 method — only that the requester
controls the server the hostname resolves to, which we do.

## Core Requirements — What Each One Fixes

| Requirement | Single-server problem it fixes |
|---|---|
| ConfigMap/Secret split | Previously `.env` was baked into the image or the host; now non-secret config and secrets are separately version-controlled and injected at runtime. |
| Postgres StatefulSet + PVC | A single Docker volume on one host meant losing the VM meant losing the database. PVCs are cluster-managed and survive pod rescheduling. |
| 2+ replicas, spread across nodes | A single container on one host had a single point of failure. `topologySpreadConstraints` guarantee replicas land on different physical nodes. |
| Migrations as a separate Job | Running `alembic upgrade head` in every replica's entrypoint races when 2+ replicas start simultaneously. A Job runs once, as an Argo CD `PreSync` hook, before any replica starts. |
| Liveness/readiness/startup probes | A crashed single container needed a manual restart. Probes let Kubernetes detect and recover automatically. |
| Resource requests/limits | An unbounded container could starve the host. Requests/limits let the scheduler place pods safely and prevent runaway usage. |
| RollingUpdate, maxUnavailable: 0 | A single-container deploy meant downtime during every release. This guarantees old replicas stay up until new ones are ready. |
| Ingress + cert-manager TLS | Manual certbot renewal on one host is fragile. cert-manager automates issuance and renewal cluster-wide. |
| Pinned image tags | `:latest` on a single host meant unpredictable rollbacks. Every deploy here references an immutable tag. |

## Advanced Requirements Implemented (3 of 5)

1. **NetworkPolicy** — default-deny in the `taskapp` namespace, with explicit
   allow rules: frontend ← Traefik (ingress), backend ← frontend, Postgres ←
   backend, plus egress rules for DNS and inter-service traffic. k3s's bundled
   NetworkPolicy controller enforces these (no separate CNI install needed).
2. **PodDisruptionBudget** — `minAvailable: 1` on both backend and frontend,
   ensuring voluntary disruptions (node drains, rolling upgrades) never take
   every replica down at once.
3. **Security hardening** — `securityContext` on every container:
   `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, and
   capabilities dropped to the minimum each image actually needs (backend runs
   fully non-root; frontend's nginx retains only `CHOWN`/`SETUID`/`SETGID`/
   `NET_BIND_SERVICE`, since the upstream image's entrypoint requires them to
   start as root and drop privileges to the `nginx` user).

## GitOps

Argo CD (`taskapp-root` Application) watches the `manifests/` directory on
`main`, with `automated` sync, `selfHeal: true`, and `prune: true`. All cluster
state shown in this document — Ingress, NetworkPolicies, the migration Job,
Secrets, Deployments — is defined in git and reconciled by Argo CD, not applied
by hand. Argo CD and cert-manager themselves are platform-level installs (done
once via their upstream install manifests), analogous to how the base OS/kubelet
aren't part of the app's own GitOps loop.
