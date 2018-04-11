locals {
  # Some AWS objects don't allow dots in their names.
  domain_without_dots = "${replace(var.domain, ".", "-")}"
  www_domain = "www.${var.domain}"
}

################################################################################
# Configure S3 Buckets                                                         #
################################################################################

# This is a secret that will be shared between CloudFront and S3 so that
# CloudFront can access the objects in an S3 bucket without making them totally
# public.
resource "random_string" "secret" {
  length = 32
}

# This policy is applied the main S3 bucket. It allows CloudFront access to the
# bucket through the use of the user-agent field through which S3 and CloudFront
# share the above secret. This kind of policy is not necessary for the redirect
# bucket since it doesn't store any objects, it just redirects. You might ask
# "why not use an s3 origin access identity to control access instead of this
# weird hack?" See https://stackoverflow.com/questions/31017105 for a discussion
# on that topic.
data "aws_iam_policy_document" "bucket" {
  statement {
    actions = [
      "s3:GetObject"
    ]

    resources = [
      # We have to construct the arn ourselves here. We can't use
      # ${aws_s3_bucket.main.arn} because that would create a circular
      # dependency between the bucket and this policy document.
      "arn:aws:s3:::${var.domain}/*",
    ]

    principals {
      type = "AWS"
      identifiers = [
        "*"
      ]
    }

    condition {
      test = "StringEquals"
      variable = "aws:UserAgent"
      values = [
        "${random_string.secret.result}"
      ]
    }
  }
}

resource "aws_s3_bucket" "main" {
  bucket = "${var.domain}"
  policy = "${data.aws_iam_policy_document.bucket.json}"
  website = {
    index_document = "index.html"
    error_document = "404.html"
  }
}

resource "aws_s3_bucket" "redirect" {
  bucket = "${local.www_domain}"
  website = {
    redirect_all_requests_to = "${aws_s3_bucket.main.id}"
  }
}

resource "aws_s3_bucket" "logs" {
  bucket = "${var.domain}-logs"
}

################################################################################
# Configure TLS Certificate                                                    #
################################################################################

resource "aws_route53_zone" "zone" {
  name = "${var.domain}"
}

resource "aws_acm_certificate" "cert" {
  domain_name = "${var.domain}"
  subject_alternative_names = [
    "${local.www_domain}"
  ]
  validation_method = "DNS"
  provider = "aws.us-east-1" # CloudFront requires certificates in this region.
}

resource "aws_route53_record" "cert_main" {
  name =
    "${lookup(aws_acm_certificate.cert.domain_validation_options[0],
              "resource_record_name")}"
  type =
    "${lookup(aws_acm_certificate.cert.domain_validation_options[0],
              "resource_record_type")}"
  records = [
    "${lookup(aws_acm_certificate.cert.domain_validation_options[0],
     "resource_record_value")}"
  ]
  zone_id = "${aws_route53_zone.zone.id}"
  ttl = 300
}

resource "aws_route53_record" "cert_redirect" {
  name =
    "${lookup(aws_acm_certificate.cert.domain_validation_options[1],
              "resource_record_name")}"
  type =
    "${lookup(aws_acm_certificate.cert.domain_validation_options[1],
              "resource_record_type")}"
  records = [
    "${lookup(aws_acm_certificate.cert.domain_validation_options[1],
     "resource_record_value")}"
  ]
  zone_id = "${aws_route53_zone.zone.id}"
  ttl = 300
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = "${aws_acm_certificate.cert.arn}"
  validation_record_fqdns = [
    "${aws_route53_record.cert_main.fqdn}",
    "${aws_route53_record.cert_redirect.fqdn}",
  ]
  provider = "aws.us-east-1" # CloudFront requires certificates in this region.
  timeouts {
    create = "2h"
  }
}

################################################################################
# Configure Simple Email Service                                               #
################################################################################

resource "aws_ses_domain_identity" "ses" {
  domain = "${var.domain}"
  provider = "aws.us-east-1" # SES not available in all regions, just hardcode.
}

resource "aws_route53_record" "ses_verification" {
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name = "_amazonses.${var.domain}"
  type = "TXT"
  ttl = "600"
  records = ["${aws_ses_domain_identity.ses.verification_token}"]
}

resource "aws_ses_domain_identity_verification" "ses" {
  domain = "${aws_ses_domain_identity.ses.id}"
  provider = "aws.us-east-1" # SES not available in all regions, just hardcode.
}

resource "aws_ses_domain_dkim" "ses" {
  domain = "${aws_ses_domain_identity_verification.ses.domain}"
  provider = "aws.us-east-1" # SES not available in all regions, just hardcode.
}

resource "aws_route53_record" "ses_dkim" {
  count = 3 # Hardcode count since we can't easily use "length" here.
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name = "${element(aws_ses_domain_dkim.ses.dkim_tokens, count.index)}._domainkey.${var.domain}"
  type = "CNAME"
  ttl = "600"
  records = ["${element(aws_ses_domain_dkim.ses.dkim_tokens, count.index)}.dkim.amazonses.com"]
}

resource "aws_ses_domain_dkim_verification" "ses" {
  domain = "${aws_ses_domain_identity_verification.ses.id}"
  provider = "aws.us-east-1" # SES not available in all regions, just hardcode.
}

################################################################################
# Configure Comment Database and Processing Lambda                             #
################################################################################

resource "aws_sns_topic" "messages" {
  name = "${local.domain_without_dots}-comments"
}

data "aws_iam_policy_document" "comment_role" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com",
        "edgelambda.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "comment" {
  name_prefix = "${var.domain}"
  assume_role_policy = "${data.aws_iam_policy_document.comment_role.json}"
}

data "aws_iam_policy_document" "comment_policy" {
  statement {
    actions = [
      "sns:Publish"
    ]

    resources = [
      "${aws_sns_topic.messages.arn}"
    ]
  }
}

resource "aws_iam_policy" "comment" {
  name = "${var.domain}-comment"
  description = "Policy for the lambda when ${var.domain}/comment is hit."
  policy = "${data.aws_iam_policy_document.comment_policy.json}"
}

resource "aws_iam_role_policy_attachment" "comment_basic" {
  role = "${aws_iam_role.comment.name}"
  policy_arn =
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "comment_custom" {
  role = "${aws_iam_role.comment.name}"
  policy_arn = "${aws_iam_policy.comment.arn}"
}

data "aws_region" "current" {
}

data "template_file" "comment" {
  template = "${file("${path.module}/files/comment.js")}"
  vars {
    domain = "${var.domain}"
    region = "${data.aws_region.current.name}"
    topic_arn = "${aws_sns_topic.messages.arn}"
  }
}

data "archive_file" "comment" {
  type = "zip"
  output_path = "${path.module}/.zip/comment.zip"
  source {
    filename = "index.js"
    content = "${data.template_file.comment.rendered}"
  }
}

resource "aws_lambda_function" "comment" {
  function_name = "${local.domain_without_dots}-comment"
  filename = "${data.archive_file.comment.output_path}"
  source_code_hash = "${data.archive_file.comment.output_base64sha256}"
  role = "${aws_iam_role.comment.arn}"
  runtime = "nodejs6.10"
  handler = "index.handler"
  memory_size = 128
  timeout = 3
  publish = true
  provider = "aws.us-east-1" # Lambda@Edge requires lambdas only in this region.
}

# Using the ItemType as a hash_key is a terrible design decision for DynamoDB
# since it can only be very small set of values, but we should be storing so
# little data in it that it hardly matters.
resource "aws_dynamodb_table" "comment" {
  name = "${var.domain}-comments"
  read_capacity  = 1
  write_capacity = 1
  hash_key = "ItemType"
  range_key = "RequestId"

  attribute {
    name = "ItemType"
    type = "S"
  }

  attribute {
    name = "RequestId"
    type = "S"
  }
}

data "template_file" "process_queue" {
  template = "${file("${path.module}/files/process_queue.py")}"
  vars {
    domain = "${var.domain}"
    region = "${data.aws_region.current.name}"
    topic_arn = "${aws_sns_topic.messages.arn}"
  }
}

data "archive_file" "process_queue" {
  type = "zip"
  output_path = "${path.module}/.zip/process_queue.zip"
  source {
    filename = "index.py"
    content = "${data.template_file.process_queue.rendered}"
  }
}

data "aws_iam_policy_document" "process_queue_role" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "process_queue_role" {
  name_prefix = "${var.domain}"
  assume_role_policy = "${data.aws_iam_policy_document.process_queue_role.json}"
}

data "aws_iam_policy_document" "process_queue_policy" {
  statement {
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Scan",
      "dynamodb:Query"
    ]

    resources = [
      "${aws_dynamodb_table.comment.arn}"
    ]
  }
}

resource "aws_iam_policy" "process_queue_policy" {
  name = "${var.domain}-process_queue"
  description = "Policy for the lambda that processes the comment Queue."
  policy = "${data.aws_iam_policy_document.process_queue_policy.json}"
}

resource "aws_iam_role_policy_attachment" "process_queue_basic" {
  role = "${aws_iam_role.process_queue_role.name}"
  policy_arn =
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "process_queue_custom" {
  role = "${aws_iam_role.process_queue_role.name}"
  policy_arn = "${aws_iam_policy.process_queue_policy.arn}"
}

resource "aws_lambda_function" "process_queue" {
  function_name = "${local.domain_without_dots}-process_queue"
  filename = "${data.archive_file.process_queue.output_path}"
  source_code_hash = "${data.archive_file.process_queue.output_base64sha256}"
  role = "${aws_iam_role.process_queue_role.arn}"
  runtime = "python3.6"
  handler = "index.handler"
  memory_size = 128
  timeout = 3
  publish = true
}

resource "aws_lambda_permission" "process_queue" {
  statement_id = "AllowSnsInvoke-${local.domain_without_dots}"
  action = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.process_queue.function_name}"
  principal = "sns.amazonaws.com"
  source_arn = "${aws_sns_topic.messages.arn}"
}

resource "aws_sns_topic_subscription" "process_queue" {
  topic_arn = "${aws_sns_topic.messages.arn}"
  protocol = "lambda"
  endpoint = "${aws_lambda_function.process_queue.arn}"
}

################################################################################
# Configure Cloudfront Distributions                                           #
################################################################################

resource "aws_cloudfront_distribution" "main" {
  enabled = true
  http_version = "http2"
  aliases = [
    "${var.domain}"
  ]
  is_ipv6_enabled = true

  origin {
    domain_name = "${aws_s3_bucket.main.website_endpoint}"
    origin_id = "S3-${var.domain}"

    custom_origin_config {
      origin_protocol_policy = "http-only"
      http_port = "80"
      https_port = "443"
      origin_ssl_protocols = [
        "TLSv1.1"
      ]
    }

    custom_header {
      name  = "User-Agent"
      value = "${random_string.secret.result}"
    }
  }

  logging_config {
    bucket          = "${aws_s3_bucket.logs.bucket_domain_name}"
    prefix          = "${var.domain}"
    include_cookies = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn =
      "${aws_acm_certificate_validation.cert.certificate_arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${var.domain}"
    compress = "true"
    viewer_protocol_policy = "redirect-to-https"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 86400

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    path_pattern = "/comment"
    target_origin_id = "S3-${var.domain}"
    compress = "true"
    viewer_protocol_policy = "redirect-to-https"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 86400

    lambda_function_association {
      event_type = "viewer-request"
      lambda_arn = "${aws_lambda_function.comment.qualified_arn}"
    }

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }
}

resource "aws_cloudfront_distribution" "redirect" {
  enabled = true
  http_version = "http2"
  aliases = [
    "${local.www_domain}"
  ]
  is_ipv6_enabled = true

  origin {
    domain_name = "${aws_s3_bucket.redirect.website_endpoint}"
    origin_id = "S3-${local.www_domain}"

    custom_origin_config {
      origin_protocol_policy = "http-only"
      http_port              = "80"
      https_port             = "443"
      origin_ssl_protocols = [
        "TLSv1.1"
      ]
    }
  }

  logging_config {
    bucket          = "${aws_s3_bucket.logs.bucket_domain_name}"
    prefix          = "${local.www_domain}"
    include_cookies = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn =
      "${aws_acm_certificate_validation.cert.certificate_arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${local.www_domain}"
    compress = "true"
    viewer_protocol_policy = "redirect-to-https"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 86400

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }
}

resource "aws_route53_record" "a_main" {
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name = "${var.domain}"
  type = "A"
  alias {
    name = "${aws_cloudfront_distribution.main.domain_name}"
    zone_id = "${aws_cloudfront_distribution.main.hosted_zone_id}"
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "a_redirect" {
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name = "${local.www_domain}"
  type = "A"
  alias {
    name = "${aws_cloudfront_distribution.redirect.domain_name}"
    zone_id = "${aws_cloudfront_distribution.redirect.hosted_zone_id}"
    evaluate_target_health = false
  }
}

################################################################################
# Configure Build Pipeline                                                     #
################################################################################

resource "aws_iam_user" "blog" {
  name = "${var.codecommit_username}"
}

resource "aws_iam_user_policy_attachment" "blog" {
  user = "${aws_iam_user.blog.name}"
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeCommitFullAccess"
}

resource "tls_private_key" "blog" {
  algorithm = "RSA"
}

resource "aws_iam_user_ssh_key" "blog" {
  username = "${aws_iam_user.blog.name}"
  encoding = "SSH"
  public_key = "${tls_private_key.blog.public_key_openssh}"
}

resource "local_file" "public_key" {
  content = "${tls_private_key.blog.public_key_openssh}"
  filename = "${var.ssh_key_path}.pub"
}

resource "local_file" "private_key" {
  content = "${tls_private_key.blog.private_key_pem}"
  filename = "${var.ssh_key_path}"
}

resource "null_resource" "chmod_private_key" {
  depends_on = ["local_file.private_key"]
  provisioner "local-exec" {
    command = "chmod 600 ${var.ssh_key_path}"
  }
}

resource "aws_codecommit_repository" "blog" {
  repository_name = "${var.domain}"
  description = "Website generating code for ${var.domain}."
}

data "aws_iam_policy_document" "codebuild_role_policy" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "codebuild.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "codebuild_role" {
  name = "${var.domain}-codebuild-role-"
  assume_role_policy =
    "${data.aws_iam_policy_document.codebuild_role_policy.json}"
}

data "aws_iam_policy_document" "codebuild_policy" {
  statement {
    actions = [
      "s3:List*",
      "s3:Put*",
      "s3:DeleteObject"
    ]

    resources = [
      "${aws_s3_bucket.main.arn}",
      "${aws_s3_bucket.main.arn}/*",
    ]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "codecommit:GitPull"
    ]

    resources = [
      "${aws_codecommit_repository.blog.arn}"
    ]
  }

  statement {
    actions = [
      "cloudfront:CreateInvalidation"
    ]

    resources = [
      "*" # A specific resource cannot be specified here.
    ]
  }
}

resource "aws_iam_policy" "codebuild_policy" {
  name = "${var.domain}-codebuild-policy"
  description = "Policy used in trust relationship with CodeBuild."
  policy = "${data.aws_iam_policy_document.codebuild_policy.json}"
}

resource "aws_iam_policy_attachment" "codebuild_policy_attachment" {
  name = "${var.domain}-codebuild-policy-attachment"
  policy_arn = "${aws_iam_policy.codebuild_policy.arn}"
  roles = [
    "${aws_iam_role.codebuild_role.id}"
  ]
}

resource "aws_codebuild_project" "blog" {
  name = "${local.domain_without_dots}-project"
  description = "Builds and publishes ${var.domain}."
  build_timeout = "5"
  service_role = "${aws_iam_role.codebuild_role.arn}"

  source {
    type = "CODECOMMIT"
    location = "${aws_codecommit_repository.blog.clone_url_http}"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image = "aws/codebuild/ubuntu-base:14.04"
    type = "LINUX_CONTAINER"
  }
}

data "archive_file" "build_trigger" {
  type = "zip"
  output_path = "${path.module}/.zip/build_trigger.zip"
  source {
    filename = "index.py"
    content = "${file("${path.module}/files/build_trigger.py")}"
  }
}

data "aws_iam_policy_document" "build_trigger_role" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "build_trigger_role" {
  name_prefix = "${var.domain}"
  assume_role_policy = "${data.aws_iam_policy_document.build_trigger_role.json}"
}

data "aws_iam_policy_document" "build_trigger_policy" {
  statement {
    actions = [
      "codebuild:StartBuild"
    ]

    resources = [
      "${aws_codebuild_project.blog.id}"
    ]
  }
}

resource "aws_iam_policy" "build_trigger_policy" {
  name = "${var.domain}-build_trigger"
  description = "Policy for the lambda when a CodeCommit push occurs."
  policy = "${data.aws_iam_policy_document.build_trigger_policy.json}"
}

resource "aws_iam_role_policy_attachment" "build_trigger_basic" {
  role = "${aws_iam_role.build_trigger_role.name}"
  policy_arn =
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "build_trigger_custom" {
  role = "${aws_iam_role.build_trigger_role.name}"
  policy_arn = "${aws_iam_policy.build_trigger_policy.arn}"
}

resource "aws_lambda_function" "build_trigger" {
  function_name = "${local.domain_without_dots}-build_trigger"
  filename = "${data.archive_file.build_trigger.output_path}"
  source_code_hash = "${data.archive_file.build_trigger.output_base64sha256}"
  role = "${aws_iam_role.build_trigger_role.arn}"
  runtime = "python3.6"
  handler = "index.handler"
  memory_size = 128
  timeout = 3
  publish = true
}

resource "aws_lambda_permission" "build_trigger_permission" {
  statement_id = "AllowCodeCommitBuildTrigger-${local.domain_without_dots}"
  action = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.build_trigger.function_name}"
  principal = "codecommit.amazonaws.com"
}

resource "aws_codecommit_trigger" "build_trigger" {
  repository_name = "${aws_codecommit_repository.blog.id}"
  trigger {
    name = "${var.domain}-build-trigger"
    destination_arn = "${aws_lambda_function.build_trigger.arn}"
    custom_data = "${aws_codebuild_project.blog.name}"
    events = [
      "updateReference"
    ]
  }
}
