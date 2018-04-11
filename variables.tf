variable "domain" {
  type = "string"
  description = "The domain name of the site."
}

variable "ssh_key_path" {
  type = "string"
  description = "The path (including filename) of the ssh private key to be generated. The key will use this path and append .pub."
}

variable "codecommit_username" {
  type = "string"
  description = "The IAM username to create for codecommit access."
}

variable "aws_region" {
  type = "string"
  description = "The AWS region in which most resources should be created."
}

provider "aws" {
  region = "${var.aws_region}"
}

# Some resources for SES and CloudFront must presently be in the us-east-1
# region
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}
