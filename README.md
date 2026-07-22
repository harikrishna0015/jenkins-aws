# Healthcare Claims Processing Platform (Claritev)

A production-style, interview-focused AWS project: an event-driven pipeline for
healthcare claims, deployed end-to-end through **Jenkins on EC2** running build
agents on **ECS (EC2 launch type)**. Both the controller and the agent hosts
use t3.micro instances, keeping the whole stack AWS free-tier-aligned.

> Healthcare is a stronger interview scenario than e-commerce — it mirrors real
> Claritev (formerly MultiPlan) workflows where hospitals continuously upload
> claim files that flow between providers, payers, and internal systems.

## Architecture
```
Hospital ──upload──▶ S3 ──ObjectCreated──▶ Lambda ──publish──▶ SNS ──fan-out──▶
  Claims Queue   ─▶ Claims Service   ─▶ DB
  Audit Queue    ─▶ Audit Service
  Notification Q ─▶ Notification Service
                                 (shared DLQ on all three)
```
Lambda is a thin **event orchestrator**: it validates the upload, reads metadata
via `head_object` (no download), and publishes to SNS. Parsing large claim
files is left to the backend service. See [`docs/architecture.md`](docs/architecture.md).

## Repository layout
```
.
├── README.md
├── Jenkinsfile                         # pipeline (runs ON the ECS agent)
├── cloudformation/
│   ├── main.yaml                       # S3->Lambda->SNS->SQS (+DLQ) healthcare stack
│   ├── jenkins-controller.yaml         # t3.micro controller + EIP + user-data
│   ├── jenkins-agent.yaml              # ECS cluster (EC2) + ASG + ECR + roles
│   ├── parameters/{dev,qa,prod}.json
│   ├── policies/                       # jenkins-policy, cfn-execution-policy (IaC artifacts)
│   └── roles/cloudformation-role.json
├── lambda/processClaims.py             # event orchestrator (boto3 + X-Ray)
├── scripts/{package,validate,deploy}.sh
├── jenkins-agent/
│   ├── Dockerfile                      # jenkins/inbound-agent + awscli/zip/jq/git
│   ├── task-definition.json            # Fargate task def for the agent
│   └── README.md
└── docs/
    ├── bootstrap-iam.md                # one-time admin setup (artifact bucket, roles, Jenkins user)
    ├── jenkins-setup.md                # install Jenkins + ECS cloud + tunnel
    └── architecture.md                 # diagrams + interview Q&A
```

## Deploy order (do these in sequence)
1. **Bootstrap IAM** (once, manual) — [`docs/bootstrap-iam.md`](docs/bootstrap-iam.md).
   Creates the artifact bucket, the CFN execution role, and the Jenkins IAM
   user whose keys go into Jenkins.
2. **Deploy the Jenkins controller** — `cloudformation/jenkins-controller.yaml`
   → t3.micro + Elastic IP + user-data that installs Jenkins/Docker/plugins.
3. **Deploy CI infra** — `cloudformation/jenkins-agent.yaml` → ECS cluster
   (EC2 launch), t3.micro container-instance ASG, ECR repo, roles.
4. **Build & push the agent image** — `jenkins-agent/README.md` → docker build,
   push to ECR, register the (EC2) task definition.
5. **Configure Jenkins** — [`docs/jenkins-setup.md`](docs/jenkins-setup.md):
   unlock, enable JNLP on 50000, configure the ECS cloud against the cluster,
   add the AWS credential, create the pipeline job.
6. **Run the pipeline** — the `Jenkinsfile` (label `ecs-fargate`) packages the
   Lambda, validates the templates, and deploys `main.yaml` via
   `cloudformation deploy --role-arn`.

## Quick smoke test (skip Jenkins, deploy by hand)
```bash
# After bootstrap-iam.md steps 1-3 and editing dev.json's BucketName:
export AWS_REGION=us-east-1
./scripts/package.sh        # (set ARTIFACT_BUCKET first)
LAMBDA_ARTIFACT_BUCKET=claims-jenkins-artifacts ./scripts/deploy.sh dev
```

## Why it's built this way (the interview answers)
- **Single `main.yaml`** — interviewers follow one template better than nested
  stacks. CI infra is split into `jenkins-controller.yaml` and
  `jenkins-agent.yaml` because it has a different lifecycle and ownership than
  the app.
- **Deploy-through-role** — Jenkins never holds broad perms; it passes a
  least-privilege CFN execution role.
- **EC2 launch type for agents** — keeps everything AWS free-tier-aligned
  (Fargate is not). The container instance runs in an ASG so you can scale to
  zero to save cost when idle.
- **Elastic IP on the controller** — a stable public address so ECS agents can
  dial JNLP directly; no tunnel needed.
- **Shared DLQ, per-queue visibility timeouts** — reflects real operational
  ownership and consumer speed differences.

## Cost
- Healthcare stack (S3/Lambda/SNS/SQS): **free-tier covered** at demo scale.
- Jenkins controller (t3.micro) + ECS container instance (t3.micro):
  free-tier is 750 hrs/month shared across all t2/t3.micro. Two always-on
  micros ≈ 1,500 hrs, so the second costs a few dollars/month. To stay free,
  stop the controller or set the ASG **DesiredCapacity = 0** when not building.
