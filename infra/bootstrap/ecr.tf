# One repository shared by dev and prod: we build once and promote the same
# image (same digest) from dev to prod. Tags are commit SHAs.

resource "aws_ecr_repository" "app" {
  name = "${var.project}-api"

  # A SHA tag can never be overwritten, so ":<sha>" in prod is guaranteed to
  # be exactly what was tested in dev.
  image_tag_mutability = "IMMUTABLE"

  # Free basic scan on push, as a second signal. The CI gate is Trivy, which
  # fails the build before anything is pushed.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Take-home trade-off: `make destroy` must also remove the images.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Drop untagged layers/manifests after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent images (rollback headroom)"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}
