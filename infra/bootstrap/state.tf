# Remote state for every stack (bootstrap, dev, prod), separated by key.
# Locking: Terraform >= 1.10 writes a `<key>.tflock` object with an S3
# conditional write (`use_lockfile = true`), so no DynamoDB table is needed.

data "aws_caller_identity" "current" {}

locals {
  # Account ID + region make the name globally unique and predictable, so the
  # Makefile can compute it without reading any state.
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # Take-home trade-off: `make destroy` must leave nothing behind. In a real
  # account this would be false plus `lifecycle { prevent_destroy = true }`.
  force_destroy = true
}

# Every write keeps the previous version: a corrupted or bad state can be
# rolled back by restoring an older object version.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256): free, no key to manage. SSE-KMS with a customer key would
# add key-policy access control and CloudTrail per-decrypt; not worth it here.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions are only useful for a short while; don't keep them forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10 # always keep the last 10 regardless of age
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# State can contain sensitive values: refuse any non-TLS access.
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"] # deny-all on plain HTTP; a Deny with * only ever removes access
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # Public access block must exist first, or S3 may reject the policy call.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
