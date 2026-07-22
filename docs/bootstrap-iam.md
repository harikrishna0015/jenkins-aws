# One-time IAM Bootstrap

These steps are done **once by an AWS administrator** before the pipeline's
first deploy. They are intentionally NOT automated in CloudFormation because
they create the very identities/roles that CloudFormation itself depends on —
a chicken-and-egg situation. This is the standard pattern in enterprises: the
"deployment identity" is bootstrapped manually, then everything it deploys is
IaC.

> Why this way? The repo holds *interview-style IaC artifacts*. An interviewer
> asking "where does the Jenkins identity come from?" gets a clean answer:
> "bootstrapped once by an admin, least-privilege, stored as artifacts here."

## 0. Get your account ID and region
```bash
aws sts get-caller-identity --query Account --output text
# e.g. 123456789012
export AWS_REGION=us-east-1
```

## 1. Create the Lambda artifact bucket
This is where the packaged `processClaims.zip` lives. The Lambda reads from it
at deploy time.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# S3 bucket names are globally unique - suffix with your account id.
aws s3api create-bucket \
  --bucket claims-jenkins-artifacts-${ACCOUNT_ID} \
  --region $AWS_REGION

# Block all public access and enforce TLS (matches the claims bucket policy).
aws s3api put-public-access-block \
  --bucket claims-jenkins-artifacts-${ACCOUNT_ID} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

> Note: the bucket name used throughout the repo is `claims-jenkins-artifacts`.
> If you suffixed it with the account id above, update `LAMBDA_ARTIFACT_BUCKET`
> in `Jenkinsfile` and the `LAMBDA_ARTIFACT_BUCKET` value you pass at deploy.

## 2. Create the CloudFormation Execution Role
This is the role Jenkins passes to `aws cloudformation deploy --role-arn`. It
holds the permissions that actually create the S3/Lambda/SNS/SQS resources —
Jenkins itself never has them.

```bash
# Edit roles/cloudformation-role.json and replace REPLACE_WITH_ACCOUNT_ID
# with your account id first.
sed -i "s/REPLACE_WITH_ACCOUNT_ID/${ACCOUNT_ID}/" cloudformation/roles/cloudformation-role.json

aws iam create-role \
  --role-name claims-cfn-execution-role \
  --assume-role-policy-document file://cloudformation/roles/cloudformation-role.json

aws iam put-role-policy \
  --role-name claims-cfn-execution-role \
  --policy-name claims-cfn-execution-policy \
  --policy-document file://cloudformation/policies/cfn-execution-policy.json
```

## 3. Create the Jenkins IAM user (least privilege)
Jenkins authenticates to AWS as this user. Its permissions are scoped by
`jenkins-policy.json` — it can upload to the artifact bucket, deploy CFN
**through the execution role**, push to ECR, and register task defs. It has no
power to create resources directly.

```bash
# Create the policy.
aws iam create-policy \
  --policy-name claims-jenkins-deploy-policy \
  --policy-document file://cloudformation/policies/jenkins-policy.json

# Create the user and attach the policy.
aws iam create-user --user-name claims-jenkins
aws iam attach-user-policy \
  --user-name claims-jenkins \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/claims-jenkins-deploy-policy

# Generate programmatic access keys - these go into Jenkins credentials.
aws iam create-access-key --user-name claims-jenkins
# => copy AccessKeyId + SecretAccessKey. Store them securely.
```

## 4. Add the AWS keys to Jenkins
In Jenkins: **Manage Jenkins → Credentials → System → Global credentials →
Add**:
- Kind: **AWS Credentials**
- ID: `aws-credentials`  *(must match the Jenkinsfile's `credentialsId`)*
- Access Key / Secret: the values from step 3.

## Checklist before first deploy
- [ ] Artifact bucket exists (step 1)
- [ ] CFN execution role exists with trust + policy attached (step 2)
- [ ] Jenkins IAM user exists, policy attached, access keys generated (step 3)
- [ ] AWS Credentials added in Jenkins with id `aws-credentials` (step 4)
- [ ] `dev.json` `BucketName` edited to be globally unique
- [ ] `AWS_REGION` correct in `Jenkinsfile` and scripts

Once this is done once, every subsequent deploy is fully automated via the
Jenkins pipeline.
