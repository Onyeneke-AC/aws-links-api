# CloudFront gives us HTTPS without owning a domain: users get
# https://<id>.cloudfront.net with AWS's certificate. TLS ends at the edge
# location nearest the user (e.g. Lagos, London).
# CloudFront -> ALB is plain HTTP over the internet (no domain = no certificate
# for the ALB); the ALB only accepts it from CloudFront carrying the secret header.

# AWS-managed policies, looked up by name rather than hard-coding their IDs.
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

locals {
  origin_id = "alb"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.name} links API"
  price_class     = var.price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = local.origin_id
    domain_name = aws_lb.this.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"] # required field; unused with http-only
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # No caching: every redirect hits the app, so links can change or be
    # deleted instantly and every click is visible in our metrics.
    cache_policy_id = data.aws_cloudfront_cache_policy.disabled.id
    # Pass method, query string, cookies and headers through; Host is replaced
    # with the ALB's own name.
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    # Adds HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy etc.
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Default *.cloudfront.net certificate. Limitation: with it, CloudFront can't
  # enforce a minimum TLS version; a custom domain + ACM cert would allow TLS 1.2+.
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.name}-cdn" }
}
