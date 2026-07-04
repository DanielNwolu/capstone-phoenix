# Cost Breakdown — Phoenix TaskApp

## Monthly Cost (us-east-1, on-demand pricing)

| Resource | Spec | Qty | Est. $/month |
|---|---|---|---|
| EC2 (control-plane) | t3.small | 1 | ~$15.00 |
| EC2 (workers) | t3.small | 2 | ~$30.00 |
| EBS (root volumes) | 8GB gp3 each | 3 | ~$2.00 |
| Data transfer (outbound) | Estimated light traffic | — | ~$1-5.00 |
| Route53 / domain | Not used (nip.io is free) | — | $0.00 |
| **Total** | | | **~$48-52/month** |

No load balancer, NAT gateway, or managed database is used — k3s's built-in
ServiceLB exposes Traefik directly on node public IPs, and Postgres runs
in-cluster on a PVC rather than RDS, keeping cost minimal for a lab-scale
deployment.

## How to Cut This in Half

The single biggest lever is **instance right-sizing combined with spot pricing**:
switching all 3 nodes to **spot instances** (t3.small spot is typically 60-70%
cheaper than on-demand) would bring compute from ~$45/month to roughly
**$15-18/month**, with the trade-off of possible node interruption — acceptable
for a lab/capstone environment where the multi-node HA design already tolerates
losing a worker gracefully (this is literally the failover scenario the project
demonstrates). Combined with stopping the cluster outside of active
development/grading windows (EC2 charges only while running), realistic
month-to-month cost for intermittent use could drop well under $10.
