# Bullet Hyperlane validator

Run a Hyperlane checkpoint validator for Bullet mainnet with Terraform or
OpenTofu. The module launches a sealed, attestable EC2 instance that generates
its own validator key inside its NitroTPM. No private key or SSH access is
required. The validator follows Bullet's message tree, signs checkpoints, and
publishes them to S3 for relayers.

## Deploy

Install OpenTofu 1.5+ (or Terraform 1.5+) and AWS CLI v2. Configure an AWS
profile with permission to create VPC, EC2, IAM and S3 resources. For an SSO
profile, run `aws sso login --profile YOUR_PROFILE` first.

Copy the following into `main.tf` in an empty directory. Change only
`bucket`, `region` and `aws_profile` in `locals`. The bucket name must be
globally unique, lowercase, and contain no dots (S3's HTTPS certificate does
not cover dotted bucket names). Use a dedicated bucket: its contents and key
names will be public.

This example creates the bucket, its public read/list policy, a VPC, a public
subnet with outbound internet, and one validator. There are no inbound
security-group rules. AWS charges for the instance, disk, public IPv4 address
and S3 usage.

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  bucket      = "my-company-bullet-validator"
  region      = "eu-west-1"
  aws_profile = "my-aws-profile"
  prefix      = "bulletmainnet"
}

provider "aws" {
  region  = local.region
  profile = local.aws_profile
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "validator" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "validator" {
  vpc_id = aws_vpc.validator.id
}

resource "aws_subnet" "validator" {
  vpc_id                  = aws_vpc.validator.id
  cidr_block              = "10.42.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "validator" {
  vpc_id = aws_vpc.validator.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.validator.id
  }
}

resource "aws_route_table_association" "validator" {
  subnet_id      = aws_subnet.validator.id
  route_table_id = aws_route_table.validator.id
}

resource "aws_s3_bucket" "validator" {
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "validator" {
  bucket                  = aws_s3_bucket.validator.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "validator" {
  bucket = aws_s3_bucket.validator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.validator.arn}/${local.prefix}/*"
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.validator.arn
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.validator]
}

module "validator" {
  source = "github.com/bulletxyz/bullet-hyperlane-validator?ref=v0.2.0"

  versions  = ["0.2.0"]
  bucket    = aws_s3_bucket.validator.id
  prefix    = local.prefix
  subnet_id = aws_subnet.validator.id

  depends_on = [aws_s3_bucket_policy.validator, aws_route_table_association.validator]
}

output "instance_ids" {
  value = module.validator.instance_ids
}
```

```sh
tofu init
tofu validate
tofu plan
tofu apply
```

The profile belongs on the root AWS provider; it is not a module input. The
module inherits that provider and discovers the AMI by owner and name in its
configured region. You do not need an AMI ID, a validator key, or a secret.

**S3 account and organization settings must also permit public bucket policies.**
`BlockPublicPolicy` and `RestrictPublicBuckets` must be disabled at every
applicable level. The example changes only this bucket's settings. Keep
SSE-S3 encryption (the default); anonymous readers cannot read SSE-KMS objects.
The validator reads anonymously even when signing. Missing public
`s3:ListBucket` permission makes S3 return 403 for missing objects and prevents
startup. Only the instance role may write under the configured prefix.

To use existing infrastructure, keep the provider and module blocks and pass
your bucket name and subnet ID. The bucket must be in the provider's region
with the policy above. The subnet needs working DNS and outbound HTTPS to
`rollup.mainnet.bullet.xyz`, GHCR and S3, through a public IPv4 address or NAT.
A bucket in another account must also grant the module's `role_arn`
`s3:PutObject` on `<prefix>/*`.

## Versions and parameters

| Pin | Current value | Meaning |
| --- | --- | --- |
| Module source `ref` | `v0.2.0` | Immutable Git tag containing this module and AMI build. |
| `versions` | `["0.2.0"]` | AMI releases to run, one instance and key per release. |
| AMI name | `hyperlane-bullet-validator-0.2.0` | Looked up automatically; owner `010222938823` (Bullet). |
| Regions | `ap-northeast-1`, `eu-north-1`, `eu-west-1` | Tokyo, Stockholm, Dublin; module and bucket use the same region. |

[Releases](https://github.com/bulletxyz/bullet-hyperlane-validator/releases)
are tagged `v<version>`. `release.json` records the AMI release, validator
container version and immutable container digest. The module ref pins the
infrastructure code; `versions` independently selects the AMIs.

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `versions` | `set(string)` | Required | AMI release versions; removing one terminates its instance and destroys its key. |
| `bucket` | `string` | Required | Dedicated public signature bucket in the provider's region. Changing it replaces all instances and keys. |
| `prefix` | `string` | Required | S3 prefix, e.g. `bulletmainnet`. Each validator writes under `<prefix>/<address>/`. Changing it replaces all instances and keys. |
| `subnet_id` | `string` | Required | Subnet with outbound internet access. Changing it replaces instances and keys. |
| `instance_type` | `string` | `c7g.medium` | Graviton/ARM64 instance type supporting NitroTPM attestation documents. T4g is unsupported. |
| `name` | `string` | `hyperlane-bullet-validator` | Prefix for resource names and EC2 Name tags. |

| Output | Meaning |
| --- | --- |
| `instance_ids` | Map from AMI release version to EC2 instance ID. |
| `role_arn` | Instance role with `s3:PutObject` on the signature prefix. |

The AMI fixes the sequencer URL to `https://rollup.mainnet.bullet.xyz` and the
Hyperlane mailbox domain to `5555`. These are measured image contents, not
module parameters. This release supports Bullet mainnet only.

## Activate with Bullet

After first boot, find the generated address:

```sh
aws s3 ls s3://YOUR_BUCKET/bulletmainnet/ --region YOUR_REGION --profile YOUR_PROFILE
```

Each `0x.../` directory contains `attestation.cbor`, `announcement.json`, and
signed checkpoints. Send Bullet the **AMI release version, validator address,
bucket, prefix and region** (or the complete HTTPS URL to that directory).
Bullet must:

1. Verify the attestation against that release's reproducible image and check
   that its attested address matches the directory.
2. Submit the signed `announcement.json` to ValidatorAnnounce on-chain.
3. Add the address to the multisig ISM's trusted validator set.

An instance that signs successfully is not an active trusted validator until
Bullet completes admission. Arrange this with Bullet before deployment.

## Verify the image

The AMI has a read-only, reproducible NixOS image built with
[AWS's NitroTPM attestation tooling](https://github.com/aws/nitrotpm-attestation-samples/tree/main/nix).
Its boot measurement covers the sequencer URL, domain and container digest.
It pulls `ghcr.io/bulletxyz/hyperlane-bullet-validator` by that digest, never
by a mutable tag. The image runs no SSH server, SSM agent or console login.
User data may contain only `s3://<bucket>/<prefix>`.

At first boot it generates a secp256k1 key in RAM, publishes an AWS-signed
attestation carrying its address, then seals the key into a NitroTPM NV index
readable only under the same PCR4 and PCR12. It never attests a pre-existing
key. Reboots retain the key; terminating the instance destroys it. Stop/start
can change attestable AMI measurements and leave the key sealed, requiring a
replacement and fresh admission.

Verification requires aarch64 Linux and Nix with flakes enabled. From a
checkout of the release tag:

```sh
jj git clone --colocate https://github.com/bulletxyz/bullet-hyperlane-validator
cd bullet-hyperlane-validator
jj new v0.2.0
curl --fail --output attestation.cbor \
  https://YOUR_BUCKET.s3.YOUR_REGION.amazonaws.com/bulletmainnet/YOUR_ADDRESS/attestation.cbor
nix run 'path:.?dir=ami#verify' -- attestation.cbor
```

The verifier rebuilds the image, checks the AWS certificate chain and PCR4/PCR12,
and prints the attested address. It must match `YOUR_ADDRESS`.

## Check progress and update

```sh
tofu output -json instance_ids
aws ec2 get-console-output --instance-id YOUR_INSTANCE_ID --latest \
  --region YOUR_REGION --profile YOUR_PROFILE --query Output --output text
curl --fail \
  https://YOUR_BUCKET.s3.YOUR_REGION.amazonaws.com/bulletmainnet/YOUR_ADDRESS/checkpoint_latest_index.json
```

Healthy logs include `Signing checkpoints`, `Reconcile complete; following new
insertions` and periodic `Audit OK: rebuilt tree matches chain history`.
Compare the checkpoint index over time as Bullet produces messages.

- **No address directory:** inspect console output. Check outbound access,
  instance type, and IAM `s3:PutObject` access to the prefix.
- **403 on reads:** check the bucket policy, all Public Access Block levels,
  and SSE-S3 encryption.
- **`HISTORY DIVERGENCE`:** the validator stops deliberately when its history
  disagrees with the chain or another key's history. Coordinate recovery with
  Bullet; do not delete checkpoints to bypass the audit.
- **AMI lookup fails:** check the release version and region against the
  release's publication status and the owner/name above.

To upgrade, pin the new module tag and add its AMI version alongside the old
one, for example `versions = ["0.2.0", "0.3.0"]`. Apply, then have Bullet
verify and admit the new address before removing the old version. Removing a
version, replacing an instance, or running `tofu destroy` destroys its key.
Keep the public checkpoint history available for relayers; the example does
not force-delete a nonempty bucket.

## Development

This repository is exported from Bullet's monorepo release pipeline. The
publisher stamps `release.json`, publishes the container, builds the sealed
image, and registers public AMIs in all three regions. For a local build on
aarch64 Linux, run `nix build 'path:.?dir=ami'` from the repository root.

[MIT license](LICENSE).
