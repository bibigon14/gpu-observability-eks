# Bootstrap

One-time setup before the first `terraform apply`. Mirrors the pattern from
terraform-eks-platform; if that bucket/table already exist, reuse them and skip steps 1-2.

## 1. Remote state backend (S3 + DynamoDB)

```bash
REGION=us-west-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="dstepanov-tfstate-${ACCOUNT}"      # reuse the existing one if present
TABLE="terraform-eks-platform-tfstate-lock" # existing lock table is fine to share

# bucket (skip if it exists)
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# lock table (skip if it exists)
aws dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$REGION"
```

Then fill `terraform/versions.tf`:
- `bucket = "<BUCKET>"`
- `dynamodb_table = "<TABLE>"`

The state key `gpu-observability-eks/terraform.tfstate` keeps this project isolated from
others in the same bucket.

## 2. GitHub OIDC (for CI apply/destroy)

If the OIDC provider from terraform-eks-platform already exists, just add a deploy role
(or reuse one) and point this repo's `AWS_ROLE_ARN` variable at it.

```bash
# OIDC provider (skip if registered)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Create a deploy role trusted by this repo. Note: on this account GitHub OIDC emits a
customized subject claim with owner/repo IDs, so the trust policy needs both patterns
(this was the AccessDenied lesson from terraform-eks-platform):

```json
{
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub": [
        "repo:bibigon14/gpu-observability-eks:*",
        "repo:bibigon14@*/gpu-observability-eks@*:*"
      ]
    },
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    }
  }
}
```

For a demo the deploy role can carry `AdministratorAccess`; scope it down for anything
real. Store its ARN as the repo variable `AWS_ROLE_ARN`, and configure a `production`
environment with a required reviewer so apply/destroy gate on approval.

## 3. GPU quota

Both G/VT quotas start at 0 on a fresh account. Request before first apply:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-3819A6DF --desired-value 8 --region us-west-2  # spot
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA --desired-value 8 --region us-west-2  # on-demand
```

## 4. First run

```bash
cd terraform
export TF_VAR_grafana_admin_password='<strong>'
terraform init
terraform plan
```
