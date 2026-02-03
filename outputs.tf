output "cloudfront_url" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

