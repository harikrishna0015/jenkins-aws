# Architecture — Healthcare Claims Processing Platform (Claritev)

## Runtime pipeline
```
Hospital (claims CSV/XML)
        │
        │  HTTPS PUT (TLS-only, enforced by DenyInsecureTransport)
        ▼
┌──────────────────────────────────────┐
│  S3 Claims Bucket (versioned, SSE)   │
│  uploads/claim_001.csv               │
│  uploads/provider_claims.xml         │
└──────────────────────────────────────┘
        │  s3:ObjectCreated:* (prefix uploads/, suffix .csv|.xml)
        ▼
┌──────────────────────────────────────┐
│  Lambda: processClaims.py            │
│  • URL-decode object key             │
│  • validate folder + extension       │
│  • head_object for size/provider     │
│  • publish event to SNS              │
└──────────────────────────────────────┘
        │  sns:Publish
        ▼
┌──────────────────────────────────────┐
│  SNS Topic (KMS-encrypted)           │   Fan-out: 1 publish → 3 queues
└──────────────────────────────────────┘
   │            │            │
   ▼            ▼            ▼
Claims Q     Audit Q     Notification Q   (each: own visibility timeout,
   │            │            │              own maxReceiveCount, shared DLQ)
   ▼            ▼            ▼
Claims svc   Audit svc   Notify svc        (poll SQS, download from S3,
                                          process, delete message)
```

### Why each piece
- **S3** = durable source of truth for the claim files. Versioning + lifecycle
  to Glacier after 90 days (claims are rarely re-read after adjudication).
- **Lambda** = thin *event orchestrator*. It validates and emits an event; it
  does **not** parse the file. A 500 MB claim batch would blow Lambda's memory
  budget — that work belongs to the downstream service. This is a deliberate
  interview talking point.
- **SNS** = fan-out. One publish notifies Claims, Audit, and Notification
  teams without Lambda knowing who they are.
- **SQS** = decoupling + independent failure handling. Each queue has its own
  visibility timeout (Claims 120s, Audit 300s, Notification 60s) reflecting how
  long each consumer takes, and all redrive to a shared DLQ after 3 failed
  receives.
- **DLQ** = shared operational triage. One team owns failed messages.

## CI/CD topology
```
GitHub repo
     │  push
     ▼
┌──────────────────────────┐
│  Jenkins controller      │  t3.micro EC2 + Elastic IP (AWS)
│  UI 8080, JNLP 50000     │  installed via CloudFormation user-data
└──────────────────────────┘
     │  schedules build on label 'ecs-fargate'
     ▼
┌──────────────────────────┐
│  ECS cluster (EC2 launch)│  backed by a t3.micro container-instance ASG
│  └ agent task            │  jenkins/inbound-agent + awscli/zip/jq/git
└──────────────────────────┘
     │  runs Jenkinsfile stages
     │   1. Package Lambda (zip + s3 cp)
     │   2. Validate CFN
     │   3. Deploy (cloudformation deploy --role-arn)
     ▼
AWS: S3 / Lambda / SNS / SQS stack
```
Both controller and agents run in AWS, so agents dial the controller's Elastic
IP on port 50000 directly — no tunnel.

### The security boundary (good interview material)
Jenkins never holds broad AWS permissions. The chain is:

```
Jenkins IAM user (least privilege: PutObject to artifact bucket,
                  PassRole, cloudformation:CreateStack/UpdateStack,
                  ecr push, ecs:RegisterTaskDefinition)
        │  passes
        ▼
CloudFormation Execution Role (claims-cfn-execution-role:
                  s3/lambda/sns/sqs/logs/iam on claims-* resources)
        │  assumes and
        ▼
Actually creates the stack's resources
```

So even if the Jenkins keys leaked, the attacker could deploy stacks but not
arbitrarily create resources in the account. This is the standard "deployment
identity + service role" pattern.

## Interview Q&A

**Q: What was your Lambda doing?**
A: Event orchestration. On S3 `ObjectCreated` it validated the upload (folder,
extension, size), read metadata via `head_object` (not a download), and
published a CLAIM_FILE_RECEIVED event to SNS, which fanned out to three SQS
queues. It deliberately does not parse the file — large batches belong in the
backend service.

**Q: Why SNS *and* SQS?**
A: SNS is push/fan-out (1 → many, no storage). SQS is pull/durable (each
consumer polls at its own speed, with retries and a DLQ). Together they give
loose coupling + reliable delivery.

**Q: How did you handle failures?**
A: Per-record try/except in the Lambda so one bad file in a batch event can't
abort the rest. At the queue level, each SQS queue has `maxReceiveCount: 3`
redriving to a shared DLQ with 14-day retention for triage.

**Q: Why deploy through a CloudFormation execution role instead of giving
Jenkins admin?**
A: Least privilege + separation of duties. Jenkins can only deploy stacks named
`claims-*` and only by passing a specific role to CloudFormation. It
has no standing permission to touch arbitrary account resources.

**Q: Why ECS agents on EC2 (EC2 launch type) instead of Fargate?**
A: EC2 launch type keeps the whole stack AWS-free-tier eligible (Fargate is
not). The container instance registers with the cluster and runs agent tasks;
the controller provisions a task per build. The trade-off is you manage one
small instance and size the host's CPU/memory.

**Q: How do cloud agents reach the controller?**
A: The controller is an EC2 instance with a public Elastic IP; its security
group opens the JNLP port (50000). ECS agents connect out to `<EIP>:50000`
directly — no tunnel. Both sides are in AWS, so it's just normal TCP.

**Q: Why URL-decode the S3 object key?**
A: S3 event keys are percent-encoded (spaces become `+`). Using the raw key in
`head_object` 404s on any filename with spaces or special chars — a classic
Lambda/S3 bug.
