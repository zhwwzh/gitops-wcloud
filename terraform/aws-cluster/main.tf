terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }

    sops = {
      source  = "carlpett/sops"
      version = "0.7.1"
    }
  }

  backend "remote" {
    hostname     = "delivery.instana.io"
    organization = "ops-aws-cluster"

    workspaces {
      prefix = "instana-"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "Environment" = "in-${terraform.workspace}"
      "ManagedBy"   = "terraform"
    }
  }
}

locals {
  max_node_count          = 256
  postgres_admin_password = data.sops_file.core_secret.data["stringData.datastorePassword"]

  cidr_index = var.region_number * 8
  vpc_cidrs  = [for i in range(0, 7) : cidrsubnet(var.base_cidr, 8, local.cidr_index + i)]

  node_label_tag_prefix = "k8s.io/cluster-autoscaler/node-template/label/"
  node_labels = flatten([for k, v in module.eks_managed_node_group : [
    for l, w in v.node_group_labels : {
      sha : sha256("${k}${l}")
      name : v.node_group_autoscaling_group_names[0]
      key : l
      value : w
    }
  ] if length(v.node_group_labels) > 0])
}

data "sops_file" "core_secret" {
  source_file = "../../regions/${terraform.workspace}/config/region-secrets.enc.yaml"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "instana" {
  filter {
    name   = "tag:Environment"
    values = ["in-${terraform.workspace}"]
  }
}

data "aws_route53_zone" "region_private" {
  name         = "${terraform.workspace}-internal.${var.domain_name}."
  private_zone = true
}

data "aws_route53_zone" "acme_challenge" {
  name         = "_acme-challenge.${var.domain_name}."
  private_zone = false
}

data "aws_kms_alias" "sops" {
  name = "alias/sops-in-${terraform.workspace}"
}

data "aws_caller_identity" "current" {}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.instana.id]
  }

  filter {
    name   = "tag:Visibility"
    values = ["private"]
  }
}

resource "aws_iam_role" "cluster_admin_role" {
  name = "in-${terraform.workspace}-eks-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          AWS = data.aws_caller_identity.current.account_id
        }
      },
    ]
  })

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

module "cluster" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "in-${terraform.workspace}"
  cluster_version = "1.24"

  vpc_id     = data.aws_vpc.instana.id
  subnet_ids = data.aws_subnets.private.ids

  cluster_endpoint_public_access = true
  enable_irsa                    = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  cloudwatch_log_group_retention_in_days = 7
}

module "eks_managed_node_group" {
  for_each = var.node_pools
  source   = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"

  name            = "in-${terraform.workspace}-${each.key}"
  cluster_name    = module.cluster.cluster_name
  cluster_version = module.cluster.cluster_version

  subnet_ids = data.aws_subnets.private.ids

  cluster_primary_security_group_id = module.cluster.cluster_primary_security_group_id
  vpc_security_group_ids            = [module.cluster.node_security_group_id]

  min_size     = each.value["min_in_pool"]
  desired_size = each.value["min_in_pool"]
  max_size     = local.max_node_count

  platform = "bottlerocket"
  ami_type = "BOTTLEROCKET_x86_64"

  bootstrap_extra_args = <<-EOT
    settings.kubernetes.cpu-manager-policy = "static"
  EOT

  instance_types = [each.value["machine_type"]]
  capacity_type  = "ON_DEMAND"

  labels = merge(
    { "instana.io/pool" = each.key },
    { for w in each.value["acceped_workloads"] : "workloads.instana.io/${w}" => "true" }
  )

  tags = {
    Pool       = each.key
    Role       = "node"
    Visibility = "private"
  }
}

resource "aws_autoscaling_group_tag" "labels" {
  for_each = {
    for k, v in local.node_labels :
    v.sha => v
  }
  autoscaling_group_name = each.value.name
  tag {
    key                 = "${local.node_label_tag_prefix}${each.value.key}"
    propagate_at_launch = true
    value               = each.value.value
  }
}

resource "aws_s3_bucket" "bucket" {
  for_each = var.object_stores

  bucket = "in-${terraform.workspace}-${each.key}"

  tags = {
    Name       = "in-${terraform.workspace}-${each.key}"
    Role       = "bucket"
    Visibility = "private"
  }
}

resource "aws_s3_bucket_versioning" "bucket_versoning" {
  for_each = var.object_stores

  bucket = aws_s3_bucket.bucket[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bucket_lifecycle" {
  for_each = var.object_stores
  bucket   = aws_s3_bucket.bucket[each.key].id

  rule {
    id     = "instana-retention"
    status = each.value > 0 ? "Enabled" : "Disabled"

    expiration {
      days = each.value > 0 ? each.value : 0
    }
  }
}

data "aws_iam_policy_document" "bucket_access" {
  statement {
    sid = "S3ReadWrite"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:ListObjetcs",
      "s3:GetBucketVersioning",
    ]

    resources = [for bucket in aws_s3_bucket.bucket : "${bucket.arn}/*"]
  }
}

data "aws_iam_policy_document" "route_53_access" {
  statement {
    sid = "ReadChanges"

    actions = [
      "route53:GetChange",
    ]

    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid = "ModifyAcmeZone"

    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]

    resources = [data.aws_route53_zone.acme_challenge.arn]
  }

  statement {
    sid = "ListZones"

    actions = [
      "route53:ListHostedZonesByName",
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "kms_access" {
  statement {
    sid = "KMSAccess"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = [data.aws_kms_alias.sops.target_key_arn]
  }
}

resource "aws_iam_policy" "bucket_access" {
  name_prefix = "in-${terraform.workspace}-k8s-buckets"
  description = "Provides access to s3 buckets for region workloads running inside of Kubernetes."
  policy      = data.aws_iam_policy_document.bucket_access.json

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

resource "aws_iam_policy" "route_53_access" {
  name_prefix = "in-${terraform.workspace}-k8s-route53"
  description = "Provides access to Route53 for region workloads running inside of Kubernetes."
  policy      = data.aws_iam_policy_document.route_53_access.json

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

resource "aws_iam_policy" "kms_access" {
  name_prefix = "in-${terraform.workspace}-k8s-kms"
  description = "Provides access to KMS for region workloads running inside of Kubernetes."
  policy      = data.aws_iam_policy_document.kms_access.json

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

module "pod_iam_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "in-${terraform.workspace}-pods"

  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  role_policy_arns = {
    buckets  = aws_iam_policy.bucket_access.arn
    route_53 = aws_iam_policy.route_53_access.arn
    kms      = aws_iam_policy.kms_access.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = var.service_account_names
    }
  }

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

resource "aws_kms_grant" "sops_decrypt_secrets" {
  name              = "${terraform.workspace}-sops-decrypt-secrets"
  key_id            = data.aws_kms_alias.sops.target_key_id
  grantee_principal = module.pod_iam_role.iam_role_arn
  operations        = ["Decrypt", "DescribeKey"]
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid = "ChangeAutoscalingGroup"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeImages",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/in-${terraform.workspace}"

      values = ["owned"]
    }

    resources = ["*"]
  }

  statement {
    sid = "DescribeAutoscalingResources"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "autoscaling_access" {
  name_prefix = "in-${terraform.workspace}-k8s-autoscaling"
  description = "Provides autoscaling capabilities to k8s workloads."
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

resource "aws_iam_policy" "lb_access" {
  name_prefix = "in-${terraform.workspace}-k8s-lb"
  description = "Provides load balancing capabilities to k8s workloads."
  policy      = file("${path.module}/iam/lb.json")

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

resource "aws_iam_policy" "efs_access" {
  name_prefix = "in-${terraform.workspace}-k8s-efs"
  description = "Provides EFS to k8s workloads."
  policy      = file("${path.module}/iam/efs.json")

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

module "aws_cluster_addons_iam_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "in-${terraform.workspace}-aws-addons"

  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  role_policy_arns = {
    autoscaling = aws_iam_policy.autoscaling_access.arn
    lb          = aws_iam_policy.lb_access.arn
    efs         = aws_iam_policy.efs_access.arn
    ebs         = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }

  oidc_providers = {
    main = {
      provider_arn = module.cluster.oidc_provider_arn
      namespace_service_accounts = [
        "kube-system:cluster-autoscaler", "kube-system:aws-load-balancer-controller", "kube-system:efs-csi-controller-sa",
        "kube-system:ebs-csi-node-sa",
        "kube-system:ebs-csi-controller-sa"
      ]
    }
  }

  tags = {
    Role       = "iam"
    Visibility = "private"
  }
}

resource "aws_security_group" "postgres" {
  name        = "in-${terraform.workspace}-pg"
  description = "Allows access to the postgres database."
  vpc_id      = data.aws_vpc.instana.id

  tags = {
    Role       = "security-group"
    Visibility = "private"
  }
}

resource "aws_security_group_rule" "postgres_default_port" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = local.vpc_cidrs
  security_group_id = aws_security_group.postgres.id
}

resource "aws_db_subnet_group" "postgres" {
  name_prefix = "in-${terraform.workspace}"
  subnet_ids  = data.aws_subnets.private.ids

  tags = {
    Name       = "in-${terraform.workspace}"
    Role       = "database"
    Visibility = "private"
  }
}

resource "aws_rds_cluster" "postgresql" {
  cluster_identifier_prefix = "in-${terraform.workspace}-pg"
  engine                    = "aurora-postgresql"

  availability_zones = data.aws_availability_zones.available.names
  database_name      = "instana"

  master_username = "instana"
  master_password = local.postgres_admin_password

  engine_mode    = "provisioned"
  engine_version = "15.2"

  backup_retention_period = 7
  preferred_backup_window = "07:00-09:00"

  storage_encrypted = true
  # Disable delete protection for non-production domains
  # TODO: Use `endswith(var.domain_name, ".io")` when we can use Terraform 1.3.0.
  skip_final_snapshot       = length(regexall(".*\\.io$", var.domain_name)) <= 0
  final_snapshot_identifier = "in-${terraform.workspace}-pg-final"

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]

  serverlessv2_scaling_configuration {
    max_capacity = 1.0
    min_capacity = 0.5
  }

  tags = {
    Role       = "database"
    Visibility = "private"
  }
}

resource "aws_rds_cluster_instance" "postgresql" {
  cluster_identifier = aws_rds_cluster.postgresql.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.postgresql.engine
  engine_version     = aws_rds_cluster.postgresql.engine_version
}

resource "aws_route53_record" "postgres_cname" {
  zone_id = data.aws_route53_zone.region_private.zone_id
  name    = "in-pg.${terraform.workspace}-internal.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_rds_cluster.postgresql.endpoint]
}