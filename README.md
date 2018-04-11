# vexing.codes-infra

Terraform code to bring up a functional static blog with a commenting system on AWS. The following resources are set up:

* A static site.
  * A Route 53 hosted zone to hold DNS records for the domain name.
  * An S3 bucket to hold the static site data.
  * An S3 bucket that redirects from `www.domain.name` to `domain.name` for both http and https.
  * A CloudFront distribution to serve data for the primary S3 bucket.
  * A CloudFront distribution to serve data for the redirecting S3 bucket.
  * A TLS certificate and corresponding DNS record for AWS's certificate manager that covers both `domain.name` and `www.domain.name` to be used by both CloudFront distributions.
  * An S3 bucket to store access logs for both of the CloudFront distributions.
* A pipeline to build the static site.
  * A CodeCommit repository to hold the code for the static site generator.
  * A CodeBuild project that builds the code from the CodeCommit repository and publishes it to the main S3 bucket.
  * A Lambda function that executes the CodeBuild project when invoked.
  * A CodeCommit trigger that executes the above Lambda upon pushes to the master branch of the CodeCommit repository.
  * An IAM user with an SSH key that is allowed access to the CodeCommit 
* A commenting system (work in progress).
  * Amazon SES setup (setup for domain identity, DKIM, and MAIL FROM).
  * An SNS topic for comment-related activities.
  * A Lambda@Edge function that gets called when `https://domain.name/comment` is visited. Simply takes all HTTP GET query parameters given to the URL and posts them to the above SNS topic.
  * A Lambda that is invoked by the above SNS topic to process comment-related activites.
  * A DynamoDB to hold to-be-moderated comments and email subscription data.

## Setup

Clone this repository. Create a file in the repository root called `terraform.tfvars` with the following content (obviously substituting your own, real values):

```
domain = "domain.name"
ssh_key_path = "/full/path/to/ssh/key"
codecommit_username = "some_username"
aws_region = us-east-1
```

Make sure you have set up your [AWS authentication](https://www.terraform.io/docs/providers/aws/) in a way Terraform understands. Then run `terraform apply` to create the infrastructure. Once the infrastructure is set up, Terraform will produce the following outputs:

```
clone-ssh = ssh://git-codecommit.us-east-2.amazonaws.com/v1/repos/some-repo
ssh-key-id = SUPERSECRETKEYID
```

From the ssh-key-id you can create some ssh config code (usually in `~/ssh/config`) that allows the repository to be cloned (substituting your SSH key path and ssh key id from above):

```
Host git-codecommit.*.amazonaws.com
  IdentityFile /full/path/to/ssh/key
  User SUPERSECRETKEYID
```

Once the SSH config is in place the repository can be cloned and pushed. The CodeBuild project uses the `buildspec.yml` file in the repository to know how to build the project, since it depends on which static site generator you are using. See the [AWS documentation](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html) for the `buildspec.yml` format.

Once code is pushed to the repository it should be automatically built and, if the `buildspec.yml` is set up correctly, it should be published to S3 and the changed files should be invalidated in the CloudFront distribution. The following is an example `buildspec.yml` for a [Hugo](https://gohugo.io/) static site (where `domain.name` is replaced with your main S3 bucket name). This example does not yet perform CloudFront invalidations though.

```
version: 0.1
environment_variables:
  plaintext:
    AWS_DEFAULT_REGION: "us-east-2"
    HUGO_VERSION: "0.38"
    HUGO_SHA256: "4c21cd4e3551fe2d0cd6bafa1825ac8f161f4a18555611193ce88570b302f533"
phases:
  install:
    commands:
      - curl -Ls https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_Linux-64bit.tar.gz -o /tmp/hugo.tar.gz
      - echo "${HUGO_SHA256} /tmp/hugo.tar.gz" | sha256sum -c -
      - tar xf /tmp/hugo.tar.gz -C /usr/local/bin
      - git submodule init
      - git submodule update
  build:
    commands:
      - hugo
  post_build:
    commands:
      - aws s3 sync --delete public s3://domain.name --cache-control max-age=3600
```

## Notes

The SES setup currently relies on two resources `aws_ses_domain_identity_verification` and `aws_ses_domain_dkim_verification` that are not yet in the mainline of [terraform-providers/terraform-provider-aws](https://github.com/terraform-providers/terraform-provider-aws). Instead [vexingcodes/terraform-provider-aws] must be built and used until the pull requests to the mainline repo are merged.

The first time I pushed the repository the lambda didn't trigger, but the second time I pushed (after creating a manual run of the CodeBuild project) it did trigger without me changing anything. I'm not yet sure why that happened (I suspect it might be something to do with the `buildspec.yml` not existing previously.)


## To Do
* The commenting system does not work yet.
* The new resources for setting up SES need to be merged into the Terraform AWS provider.
* The SES "MAIL FROM" domain needs to be set up automatically. This is not really necessary, just a nice touch.
* Even though SES is set up automatically, a ticket still has to be manually submitted in order to get sending restrictions lifted. This needs to be documented.
* Need to figure out how SES email templates can be set up for comment notifications.
