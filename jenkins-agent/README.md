# Jenkins ECS Build Agent Image

This directory builds the Docker image for the Jenkins **inbound (JNLP) agent**
that runs pipeline builds on **ECS (EC2 launch type)**.

The image is the official `jenkins/inbound-agent` with the AWS CLI v2, `zip`,
`jq`, and `git` added — everything the `Jenkinsfile` stages need.

## Files
- `Dockerfile` — agent image definition.
- `task-definition.json` — Fargate task definition registered to ECS; the
  Jenkins ECS plugin launches a task from this family for each build.

## Prerequisites
Deploy the CI infrastructure stack first (creates the ECS cluster, container
instances, ECR repo + roles):

```bash
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

Grab the outputs (you'll paste these into `task-definition.json`):

```bash
aws cloudformation describe-stacks --stack-name claims-jenkins-infra \
  --query 'Stacks[0].Outputs' --output table
```

## 1. Build the image

```bash
cd jenkins-agent
docker build -t claims/jenkins-agent .
```

## 2. Authenticate to ECR and push

```bash
AWS_REGION=us-east-1   # adjust
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
    $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker tag claims/jenkins-agent:latest \
  $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/claims/jenkins-agent:latest

docker push $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/claims/jenkins-agent:latest
```

## 3. Register the task definition

Replace the four placeholders in `task-definition.json`
(`<AWS_REGION>`, `<ACCOUNT_ID>`, `<EXEC_ROLE_ARN>`, `<TASK_ROLE_ARN>`) using
the stack outputs, then:

```bash
aws ecs register-task-definition \
  --cli-input-json file://jenkins-agent/task-definition.json
```

## 4. Point Jenkins at it
In the Jenkins ECS cloud config (see `docs/jenkins-setup.md`), set:
- **Task definition**: `claims-jenkins-agent` (the family, or the full
  `family:revision` from the previous step)
- **Label**: `ecs-fargate`
- **Jenkins tunnel**: `<controller-EIP>:50000`

When a pipeline requests label `ecs-fargate`, Jenkins launches a task from this
family onto a registered container instance in the `claims-jenkins-cluster`,
the agent connects out to the controller's Elastic IP over JNLP, runs the build,
and the task is stopped when the build finishes. The container instance stays
registered for the next build; set the ASG `DesiredCapacity` to 0 to fully
scale down when idle.
