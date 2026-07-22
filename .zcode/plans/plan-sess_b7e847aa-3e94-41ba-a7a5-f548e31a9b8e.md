# Healthcare Claims Platform — Repo + Jenkins + ECS Fargate Agent

## Final repo layout
```
aws-event-driven-project/
├── README.md                      # architecture, deploy order, interview talking points
├── Jenkinsfile                    # pipeline (runs ON the ECS agent, label 'ecs-fargate')
├── .gitignore
├── cloudformation/
│   ├── main.yaml                  # S3->Lambda->SNS->SQS(Claims/Audit/Notification)+DLQ
│   ├── jenkins-agent.yaml         # ECS cluster, ECR, exec/task roles, log group
│   └── parameters/{dev,qa,prod}.json
├── cloudformation/policies/{jenkins-policy,cfn-execution-policy}.json
├── cloudformation/roles/cloudformation-role.json
├── lambda/processClaims.py        # event orchestrator (with the 3 fixes)
├── scripts/{package,validate,deploy}.sh
├── jenkins-agent/
│   ├── Dockerfile                 # jenkins/inbound-agent + awscli v2, zip, jq, git
│   ├── task-definition.json       # registered to ECS; referenced by Jenkins ECS plugin
│   └── README.md                  # build/push to ECR steps
└── docs/
    ├── jenkins-setup.md           # install Jenkins on Windows + plugins + credentials + ECS cloud
    ├── bootstrap-iam.md           # one-time admin steps (artifact bucket, cfn exec role)
    └── architecture.md            # diagrams + interview Q&A
```

## Part 1 — Healthcare infra (from your paste, + fixes)
- `cloudformation/main.yaml`: use your complete template verbatim (it's correct). Parameters: Environment, ProjectName, BucketName, LambdaMemory, LambdaTimeout, LambdaArtifactBucket, LambdaArtifactKey.
- `lambda/processClaims.py`: same logic, + 3 fixes (URL-decode key via `unquote_plus`, per-record try/except, keep `patch_all` but bundle the SDK via package.sh).
- `scripts/package.sh`: pip-install `boto3`, `aws-xray-sdk` into a staging dir, zip, upload to artifact bucket.
- `scripts/validate.sh`: `aws cloudformation validate-template`.
- `scripts/deploy.sh`: `aws cloudformation deploy` with `--role-arn`, `--capabilities CAPABILITY_NAMED_IAM`.
- `cloudformation/parameters/*.json`: dev/qa/prod with realistic values (bucket names have a placeholder suffix the user edits for global uniqueness).
- `cloudformation/policies/*` and `roles/*`: exactly as you designed (Jenkins least-privilege policy, CFN execution policy, CFN trust role). These are one-time admin artifacts.

## Part 2 — Jenkins agent infra (new)
- `cloudformation/jenkins-agent.yaml` (Fargate) provisions: ECS cluster, ECR repo (`claritev/jenkins-agent`), task-execution role (ECR pull + CloudWatch logs), minimal task role, CloudWatch log group. Uses default VPC subnets/SG passed as params.
- `jenkins-agent/Dockerfile`: `FROM jenkins/inbound-agent:latest`; as root install `awscli` v2, `zip`, `jq`, `git`, `curl`; switch back to `jenkins` user; keep the inbound entrypoint so the ECS plugin can pass JNLP args.
- `jenkins-agent/task-definition.json`: Fargate task referencing the ECR image, the exec role, log group, CPU/mem (512/1024 — cheapest Fargate, ~$0.02/build).
- Build & push steps (documented in jenkins-agent/README.md): `docker build` → `aws ecr get-login-password` → tag → push.

## Part 3 — Jenkins controller setup (documented, not code)
`docs/jenkins-setup.md` covers the full local-on-Windows path:
1. Install Jenkins via `jenkins.msi` (runs as a Windows service, port 8080).
2. Install plugins: **Amazon EC2 Container Service (ECS) plugin**, **AWS Credentials**, **Pipeline**, **Git**.
3. Add credential: AWS access key + secret (type "AWS Credentials"), ID `aws-credentials`.
4. Expose controller for cloud agents: run an ngrok/Cloudflare TCP tunnel on the JNLP port (50000) since the controller is local and Fargate is in AWS. Document the tunnel command + Jenkins "TCP port for inbound agents" setting.
5. Configure the ECS cloud in Jenkins: region, cluster, subnets, SG, label `ecs-fargate`, container image = ECR URI, task role = exec role, and the `task-definition.json` family.
6. Create a Pipeline job pointing at this repo's `Jenkinsfile`.

## Part 4 — The pipeline (`Jenkinsfile`)
Declarative pipeline, `agent { label 'ecs-fargate' }`. Stages:
- **Checkout** SCM.
- **Package Lambda** → run `scripts/package.sh` (zip + upload to artifact bucket).
- **Validate IaC** → `scripts/validate.sh`.
- **Deploy (dev)** → `scripts/deploy.sh dev`.
- AWS keys injected via `withCredentials([aws()])` → exported as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for the scripts. No keys in code.

## One-time bootstrap (documented in docs/bootstrap-iam.md, done manually once — not by the repo)
Because the repo is *interview-style IaC artifacts* (per your design), an admin does these once before first deploy:
1. Create the artifact bucket (referenced by `LambdaArtifactBucket`).
2. Create the CFN execution role (`cloudformation-role.json` trust + `cfn-execution-policy.json` perms).
3. Create the Jenkins IAM user + attach `jenkins-policy.json`; generate its access keys → paste into Jenkins credentials.

## Deploy order (the order matters)
1. Bootstrap IAM + artifact bucket (once).
2. `aws cloudformation deploy` `jenkins-agent.yaml` → get ECR URI.
3. Build & push agent image to ECR.
4. `aws ecs register-task-definition` from `task-definition.json`.
5. Install/configure local Jenkins + ECS cloud (point at the task family + ECR image).
6. Deploy `main.yaml` via the Jenkins pipeline (or `scripts/deploy.sh dev` manually to smoke-test).

## Notes on free tier / cost
- Healthcare stack (S3/Lambda/SNS/SQS) = free-tier covered, effectively $0 at demo scale.
- ECS Fargate agent = NOT free tier, but ~$0.01–0.05 per build (runs only during builds, scales to zero). Negligible for learning.

## What I will NOT do
- I won't run any real AWS deploys or push images (no credentials here) — I'll produce the files + docs and the exact commands for you to run.
- I won't modify anything outside this repo.

I'll implement all files in one pass, then walk you through the bootstrap + Jenkins config steps.