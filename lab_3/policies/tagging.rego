# Mandatory resource tagging.
#
# Every taggable resource MUST carry these four tags:
#   Environment, Application, Owner, CostCenter
#
# Data-handling S3 buckets additionally MUST carry:
#   DataClass
package main

import future.keywords.in

required_tags := ["Environment", "Application", "Owner", "CostCenter"]

# ----- S3 buckets: 4 mandatory tags + DataClass --------------------------------

deny[msg] {
	change := input.resource_changes[_]
	change.type == "aws_s3_bucket"
	change.change.actions[_] in ["create", "update"]

	tag := required_tags[_]
	not change.change.after.tags[tag]

	msg := sprintf(
		"S3 bucket '%s' missing required tag: %s",
		[bucket_label(change), tag],
	)
}

deny[msg] {
	change := input.resource_changes[_]
	change.type == "aws_s3_bucket"
	change.change.actions[_] in ["create", "update"]

	not change.change.after.tags.DataClass

	msg := sprintf(
		"S3 bucket '%s' missing required tag: DataClass",
		[bucket_label(change)],
	)
}

# ----- Lambda functions: 4 mandatory tags --------------------------------------

deny[msg] {
	change := input.resource_changes[_]
	change.type == "aws_lambda_function"
	change.change.actions[_] in ["create", "update"]

	tag := required_tags[_]
	not change.change.after.tags[tag]

	msg := sprintf(
		"Lambda '%s' missing required tag: %s",
		[lambda_label(change), tag],
	)
}

# ----- Helpers -----------------------------------------------------------------

# Prefer the Terraform resource name (e.g. "data_bucket") for human readability,
# fall back to the bucket name attribute, fall back to the address.
bucket_label(change) := name {
	parts := split(change.address, ".")
	name := parts[count(parts) - 1]
}

lambda_label(change) := name {
	name := change.change.after.function_name
}

lambda_label(change) := name {
	not change.change.after.function_name
	parts := split(change.address, ".")
	name := parts[count(parts) - 1]
}
