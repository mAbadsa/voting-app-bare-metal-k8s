# Automated etcd Backup

Production-style automation of etcd disaster recovery: scheduled
snapshots, verified before upload, shipped to S3, with local retention
cleanup. Builds on the manual snapshot/restore procedure documented in
[`advanced-operations.md`](advanced-operations.md#2-etcd-backup-and-restore) —
read that first if you want the conceptual background on static pods and
why etcd needs to be stopped for a restore.

---

## Why automate this

A manual snapshot is only useful if someone remembers to take it — and
takes it *before* the moment it's needed, not after. Automation turns a
one-off exercise into an actual safety net:

- Runs on a schedule, independent of anyone remembering to do it
- Verifies each snapshot before trusting it (`etcdctl snapshot status`)
- Ships backups off-node to S3, so a lost/corrupted VM disk doesn't take
  the backup down with it
- Enforces a retention policy so backups don't silently fill the disk

---

## Architecture

```
cron (every 6h)
   │
   ▼
scripts/etcd-backup.sh
   │
   ├─ 1. ensure /var/backups/etcd exists
   ├─ 2. etcdctl snapshot save
   ├─ 3. etcdctl snapshot status   (verify before trusting it)
   ├─ 4. aws s3 cp  →  S3 bucket
   └─ 5. find -mtime +7 -delete    (local cleanup)

S3 bucket
   └─ lifecycle rule: expire objects after 30 days
      (second layer of retention, independent of the script)
```

---

## S3 bucket setup

```bash
BUCKET_NAME="my-etcd-backups-<unique-suffix>"
REGION="<your-region>"

aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"

# Block all public access — etcd snapshots contain full cluster state,
# including Secrets
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Lifecycle rule as a second, independent layer of retention
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-old-backups",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": {"Days": 30}
    }]
  }'
```

## IAM: least-privilege access

The backup script runs as a **dedicated IAM user**, scoped to only this
bucket — not the account's admin credentials, and not broad,
account-wide S3 access.

```bash
aws iam create-user --user-name etcd-backup-uploader
```

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-etcd-backups-<unique-suffix>",
        "arn:aws:s3:::my-etcd-backups-<unique-suffix>/*"
      ]
    }
  ]
}
```

```bash
aws iam put-user-policy --user-name etcd-backup-uploader \
  --policy-name etcd-backup-s3-access \
  --policy-document file://etcd-backup-policy.json

aws iam create-access-key --user-name etcd-backup-uploader
```

Configure the resulting credentials **on the control-plane node**
(where the script runs), not on a personal machine:
```bash
# on the control plane
aws configure
```

> **Design choice:** broader permissions like `s3:ListAllMyBuckets`
> (account-wide bucket visibility) are deliberately *not* granted to
> this user — the script never needs to see any bucket but its own.
> That kind of convenience permission belongs on a personal/admin IAM
> user, not an automation account.

---

## Running it

```bash
sudo scripts/etcd-backup.sh
```

Verify the upload:
```bash
aws s3 ls s3://my-etcd-backups-<unique-suffix>/$(hostname)/
```

## Scheduling it

```bash
sudo crontab -e
```
```
0 */6 * * * /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

---

## What this doesn't cover yet

Being upfront about the gap between this and a fully production-grade
setup:

- **No alerting on backup failure or staleness.** A production setup
  would pair this with a Prometheus alert (or similar) firing if no
  successful backup has completed within an expected window — a silent
  cron failure is worse than no backup, since it creates false
  confidence.
- **No restore drills scheduled.** The manual restore in
  `advanced-operations.md` proves the mechanism works once; a real
  backup strategy re-validates that on a recurring basis (see the note
  on restore drills there).
- **Single-node etcd**, not a 3/5-member HA cluster — this cluster's
  etcd has no built-in redundancy of its own, which is exactly why this
  backup layer matters more here than it would on a properly quorum'd
  production control plane.

---

## Files

- [`scripts/etcd-backup.sh`](../scripts/etcd-backup.sh) — the backup script itself
- [`advanced-operations.md`](advanced-operations.md) — manual restore walkthrough and the concepts behind it
