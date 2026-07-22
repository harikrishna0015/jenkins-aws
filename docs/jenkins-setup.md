# Jenkins Setup (EC2 Controller + ECS EC2 Agents)

The architecture: a **t3.micro EC2 controller** running Jenkins, plus an
**ECS cluster (EC2 launch type)** backed by t3.micro container instances that
run the build agent containers. Both live in AWS, so agents reach the
controller directly over JNLP — **no tunnel required**.

> The controller user-data already installs Jenkins, Docker, Java 17, and the
> key plugins, so first boot is hands-off. You just grab the admin password and
> configure the ECS cloud.

---

## 0. Prerequisites
- A default VPC with at least one public subnet (AWS accounts ship with one).
- An EC2 key pair in your region (for SSH to the controller).
- Your AWS account id and region.

Grab these to fill into the deploys below:
```bash
aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text
aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
  --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output table
```

## 1. Deploy the Jenkins controller (t3.micro)
```bash
aws cloudformation deploy \
  --stack-name claims-jenkins-controller \
  --template-file cloudformation/jenkins-controller.yaml \
  --parameter-overrides \
      ProjectName=claims \
      VpcId=<your-default-vpc> \
      SubnetId=<a-public-subnet> \
      KeyName=<your-key-pair> \
  --capabilities CAPABILITY_NAMED_IAM
```

Get the controller's stable public address from outputs:
```bash
aws cloudformation describe-stacks --stack-name claims-jenkins-controller \
  --query 'Stacks[0].Outputs' --output table
```
Note **JenkinsUrl** (`http://<EIP>:8080`) and **JnlpEndpoint** (`<EIP>:50000`).

Give user-data ~3–5 min to finish installing Jenkins, then open the UI.

## 2. Unlock Jenkins + finish web setup
1. Browse to `http://<EIP>:8080`.
2. Get the initial admin password from the box:
   ```bash
   ssh -i <your-key>.pem ec2-user@<EIP> "sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
   ```
3. Choose **Select plugins to install** and confirm these are present (the
   user-data pre-installs the core set):
   - **Amazon EC2 Container Service (ECS)** — launches agents on ECS
   - **AWS Credentials** — stores AWS keys, binds them in the pipeline
   - **Pipeline**, **Git**, **Blue Ocean** (optional)
4. Create your admin user.

## 3. Enable inbound agents on the controller
**Manage Jenkins → Security → Agents** (or *Configure Global Security* on older
versions):
- **TCP port for inbound agents**: **Fixed 50000**.

The controller SG already allows inbound 50000 (see
`cloudformation/jenkins-controller.yaml`), so ECS agents can reach it.

## 4. Deploy the ECS agent infra (cluster + container instances + ECR)
```bash
# Default-VPC subnets as a comma list:
SUBNETS=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

aws cloudformation deploy \
  --stack-name claims-jenkins-infra \
  --template-file cloudformation/jenkins-agent.yaml \
  --parameter-overrides \
      ProjectName=claims \
      EcrRepoName=claims/jenkins-agent \
      VpcId=<your-default-vpc> \
      "SubnetIds=${SUBNETS}" \
  --capabilities CAPABILITY_NAMED_IAM
```

This creates:
- the ECS cluster `claims-jenkins-cluster`,
- an ASG with **1 desired** t3.micro **ECS-optimized** container instance
  (registered into the cluster via user-data),
- the ECR repo `claims/jenkins-agent`,
- the task execution + task roles.

Give the container instance a minute or two to register, then confirm:
```bash
aws ecs list-container-instances --cluster claims-jenkins-cluster
```

## 5. Build & push the agent image
Run these locally (or from the controller — it has Docker too):
```bash
cd jenkins-agent
docker build -t claims/jenkins-agent .

AWS_REGION=<region>
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_URI

docker tag claims/jenkins-agent:latest ${ECR_URI}/claims/jenkins-agent:latest
docker push ${ECR_URI}/claims/jenkins-agent:latest
```

## 6. Register the Fargate-free (EC2) task definition
Replace the placeholders in `jenkins-agent/task-definition.json`
(`<ACCOUNT_ID>`, `<AWS_REGION>`, `<EXEC_ROLE_ARN>`, `<TASK_ROLE_ARN>` — all from
the `claims-jenkins-infra` stack outputs), then:
```bash
aws ecs register-task-definition \
  --cli-input-json file://jenkins-agent/task-definition.json
```

## 7. Configure the ECS Cloud in Jenkins
**Manage Jenkins → Clouds → New cloud**:
- Name: `ecs-fargate-cloud`
- Type: **Amazon EC2 Container Service Cloud**
- **Amazon ECS cluster name**: `claims-jenkins-cluster`
- **Region**: your region
- **ECS Template** (add one):
  - **Label**: `ecs-fargate` *(must match `Jenkinsfile` `agent { label ... }`)*
  - **Task definition**: `claims-jenkins-agent` (the family from step 6)
  - **Container name** (required by plugin): `jenkins-agent`
  - **Jenkins tunnel**: `<EIP>:50000` *(from controller stack output)*
  - **Jenkins URL**: `http://<EIP>:8080`

> Because the controller has a public IP on the fixed Elastic IP, there is no
> tunnel — agents simply dial the EIP. (If you later lock port 50000 down to
> the agent security group instead of `0.0.0.0/0`, you can remove public
> exposure — the agents are in the same account but different SGs, so reference
> the container-instance SG as the source.)

Save and **Test connection**.

## 8. Add the AWS credential + create the pipeline
1. Add the Jenkins IAM user keys as an **AWS Credentials** entry with id
   `aws-credentials` (see `docs/bootstrap-iam.md` step 4).
2. **New Item → Pipeline**, Definition **Pipeline script from SCM**, point at
   your repo, Script Path `Jenkinsfile`. **Build Now.**

The first build provisions an ECS task on the container instance, the agent
connects to the controller, and the pipeline runs Package → Validate → Deploy.

---

## Cost & free-tier note
The AWS free tier gives **750 hours/month** of t2/t3.micro, shared across all
such instances. With a **running controller + a running container instance**
you run *two* t3.micros simultaneously ≈ 1,500 instance-hours/month — so the
second instance is outside free tier and costs a few dollars/month.

To stay fully free-tier during learning:
- set the container-instance ASG **DesiredCapacity = 0** when you're not
  building (edit `jenkins-agent.yaml`, or scale via the console), or
- stop the controller EC2 when idle (the Elastic IP stays attached, so the
  address is stable across stops).

## Troubleshooting
| Symptom | Likely cause |
|---|---|
| Build hangs at "Still waiting to schedule" | Agent task can't reach controller — verify JNLP endpoint is `<EIP>:50000` and SG port 50000 is open |
| No container instances in cluster | ASG instance still booting, or wrong subnets/key; check `aws ecs list-container-instances` |
| `No Container Instances were found` on task launch | Cluster has instances but none have enough free CPU/mem — reduce task `cpu`/`memory` or scale the ASG |
| `CannotPullContainerError` | ECR login / execution role perms, or wrong image URI |
| `AccessDenied` on `s3 cp` / `cloudformation deploy` | Jenkins AWS keys (see `docs/bootstrap-iam.md`) |
