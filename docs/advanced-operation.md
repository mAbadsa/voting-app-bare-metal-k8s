# Advanced Operations Exercises

Hands-on exercises performed on this cluster beyond the initial deployment,
covering failure recovery and observability — the operational concerns a
managed Kubernetes service (EKS/GKE/minikube) normally handles for you.

---

## 1. Simulating a Node Failure and Recovery

**Goal:** observe how the cluster reschedules workloads when a node goes
down, and confirm it recovers cleanly when the node comes back.

### Step 1 — Check current pod distribution

```bash
kubectl get pods -n voting-app -o wide
```
Note which pods are running on `node-1` vs `node-2`.

### Step 2 — Simulate a node failure

From your host machine (not inside the VM):
```bash
multipass stop node-1
```

### Step 3 — Watch the cluster react

From the control plane:
```bash
kubectl get nodes -w
```
After roughly 40 seconds (the default `node-monitor-grace-period`),
`node-1` will flip to `NotReady`.

In another terminal, watch the pods:
```bash
kubectl get pods -n voting-app -o wide -w
```

**What to expect:** pods that were running on `node-1` do **not**
reschedule immediately — by default, Kubernetes waits
`pod-eviction-timeout` (5 minutes) before evicting pods from a node it
can no longer reach, to avoid overreacting to a brief network blip. After
that timeout, pods are rescheduled onto remaining `Ready` nodes (if they
have capacity and there's no `PersistentVolume` tying them to that
specific node).

> Note: pods backed by a `PersistentVolumeClaim` using node-local storage
> (e.g. `hostPath`) will **not** reschedule successfully elsewhere — this
> is a real, common production issue, and part of why network-attached
> storage is preferred for stateful workloads in multi-node clusters.

### Step 4 — Recover the node

```bash
multipass start node-1
```

Confirm it rejoins cleanly:
```bash
kubectl get nodes
kubectl get pods -n voting-app -o wide
```
`node-1` should return to `Ready`, and — depending on your Deployment's
`replicas` count and what was evicted — new pods may schedule back onto
it as the scheduler rebalances.

### What this demonstrates
Understanding of Kubernetes self-healing behavior, eviction timing, and
the practical difference between "a node is down" and "workloads have
actually moved" — a distinction that matters a great deal in an incident.

---

## 2. etcd Backup and Restore

**Goal:** back up the cluster's entire state (etcd is where every
Kubernetes object — Deployments, Secrets, ConfigMaps, everything — is
actually stored) and practice restoring from that backup.

> Run all of this on the **control plane** node, since that's where the
> static etcd pod lives.

### Step 1 — Install `etcdctl`

```bash
sudo apt install -y etcd-client
```

### Step 2 — Locate the certificates etcd needs for authentication

```bash
sudo ls /etc/kubernetes/pki/etcd/
```
You'll use `ca.crt`, `server.crt`, and `server.key` from here.

### Step 3 — Take a snapshot

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Verify it:
```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup.db --write-out=table
```

### Step 4 — Simulate data loss

Delete something visible so the restore is easy to confirm afterward:
```bash
kubectl delete namespace voting-app
kubectl get namespaces   # confirm it's gone
```

### Step 5 — Restore from the snapshot

Stop the API server and etcd (moving their static pod manifests out of
the watched directory stops them):
```bash
sudo mkdir -p /tmp/manifests-backup
sudo mv /etc/kubernetes/manifests/*.yaml /tmp/manifests-backup/
```

Restore the snapshot into a fresh data directory:
```bash
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd-restored
```

Point etcd's manifest at the restored data directory — edit the etcd
static pod manifest (`/tmp/manifests-backup/etcd.yaml`) and change the
`hostPath` for its data volume from `/var/lib/etcd` to
`/var/lib/etcd-restored`, then move all manifests back:
```bash
sudo mv /tmp/manifests-backup/*.yaml /etc/kubernetes/manifests/
```

### Step 6 — Confirm the restore worked

Give the control plane a minute to come back up, then:
```bash
kubectl get namespaces
kubectl get pods -n voting-app
```
`voting-app` should be back — restored from the point-in-time snapshot.

### What this demonstrates
Practical disaster-recovery experience with the single most critical
piece of cluster state — most engineers who've *used* Kubernetes have
never actually performed an etcd restore.

---

A production-style automation of this procedure — scheduled, verified, and shipped to S3 — is documented in [etcd-backup-automation.md](etcd-backup-automation.md).

---

## 3. Basic Monitoring with Prometheus and Grafana

**Goal:** get cluster and pod-level metrics visualized, using the
community-standard `kube-prometheus-stack` Helm chart.

### Step 1 — Install Helm (if not already installed)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Step 2 — Add the Prometheus community Helm repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 3 — Install the stack

```bash
kubectl create namespace monitoring
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring
```

This installs Prometheus, Grafana, Alertmanager, and the exporters
needed to scrape node/pod/cluster metrics — all pre-wired together.

### Step 4 — Wait for it to roll out

```bash
kubectl get pods -n monitoring -w
```

### Step 5 — Expose Grafana

The chart installs Grafana as a `ClusterIP` Service by default. Patch it
to `NodePort` for the same reason we did with `vote`/`result`:
```bash
kubectl patch svc monitoring-grafana -n monitoring \
  -p '{"spec": {"type": "NodePort"}}'
kubectl get svc monitoring-grafana -n monitoring
```

### Step 6 — Log in

Default credentials are `admin` / `prom-operator` (chart default — change
this if you keep the cluster running long-term).

```bash
curl -I http://<any-node-ip>:<nodeport-from-step-5>
```
Or open it in a browser. Explore the pre-built dashboards — Kubernetes /
Compute Resources / Cluster is a good first stop.

### What this demonstrates
Familiarity with the industry-standard observability stack, Helm as a
package manager, and enough comfort to reason about what's actually
running (rather than just clicking through a demo).

---

## Notes for Interviews

These exercises are useful precisely because they surface real
trade-offs and failure modes — talk about *what you observed*, not just
that you ran the commands: how long eviction actually took, what broke
when a node went down, what the etcd restore process assumes (a
consistent snapshot, a stopped API server), and what Grafana's default
dashboards do and don't tell you out of the box.
