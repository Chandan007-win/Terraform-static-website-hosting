provider "aws" {
  region = "ap-south-1" # CloudFront requires this for ACM (later)
}

# ----------------------
# S3 Bucket for Static Site
# ----------------------
resource "aws_s3_bucket" "static_site" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "ownership" {
  bucket = aws_s3_bucket.static_site.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "block_public" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------
# Upload index.html with etag (auto detects changes)
# ----------------------
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_site.id
  key          = "index.html"
  source       = "website/index.html"
  content_type = "text/html"

  etag = filemd5("website/index.html")  # triggers update when HTML changes
}

# ----------------------
# Upload all images with etag (auto detects changes)
# ----------------------
resource "aws_s3_object" "images" {
  for_each = fileset("website/images", "*")
  bucket   = aws_s3_bucket.static_site.id
  key      = "images/${each.value}"
  source   = "website/images/${each.value}"
  acl      = "public-read"
  etag     = filemd5("website/images/${each.value}")
}

# ----------------------
# CloudFront Origin Access Control
# ----------------------
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac"
  description                       = "OAC for S3 static site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ----------------------
# CloudFront Distribution
# ----------------------
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin"

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ----------------------
# S3 Bucket Policy for CloudFront
# ----------------------
resource "aws_s3_bucket_policy" "policy" {
  bucket = aws_s3_bucket.static_site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = "s3:GetObject"
        Resource = "${aws_s3_bucket.static_site.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# ----------------------
# Automatic CloudFront Invalidation for index.html
# ----------------------
resource "null_resource" "invalidate_html" {
  triggers = {
    index_html_hash = filemd5("website/index.html")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws cloudfront create-invalidation \
        --distribution-id ${aws_cloudfront_distribution.cdn.id} \
        --paths "/index.html"
    EOT
  }
}

# ----------------------
# Automatic CloudFront Invalidation for images
# ----------------------
resource "null_resource" "invalidate_images" {
  triggers = {
    images_hash = join(",", [for f in fileset("website/images", "*") : filemd5("website/images/${f}")])
  }

  provisioner "local-exec" {
    command = <<EOT
      aws cloudfront create-invalidation \
        --distribution-id ${aws_cloudfront_distribution.cdn.id} \
        --paths "/*"
    EOT
  }
}

