# The bucket is created outside Terraform on purpose. Terraform can't store its
# own state in a bucket it hasn't created yet, and putting the bucket under
# management here means `destroy` would try to delete the thing holding the
# state it's reading from.
#
# Bootstrap (once per account):
#   aws s3api create-bucket --bucket emartapp-tfstate-<account-id> \
#     --region eu-north-1 --create-bucket-configuration LocationConstraint=eu-north-1
#   aws s3api put-bucket-versioning --bucket emartapp-tfstate-<account-id> \
#     --versioning-configuration Status=Enabled
#
# Versioning matters more than it looks: it's the difference between a corrupted
# state file being an inconvenience and being unrecoverable.

terraform {
  backend "s3" {
    bucket       = "emartapp-tfstate-753675398762"
    key          = "emartapp/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}
