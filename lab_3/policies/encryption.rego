# S3 encryption-at-rest.
#
# The AWS Terraform provider removed inline `server_side_encryption_configuration`
# from the `aws_s3_bucket` schema in v4.0 (Feb 2022). The current pattern is a
# paired, standalone resource:
#
#     resource "aws_s3_bucket" "data_bucket" { ... }
#     resource "aws_s3_bucket_server_side_encryption_configuration" "data_bucket" {
#       bucket = aws_s3_bucket.data_bucket.id
#       rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
#     }
#
# At plan time the encryption resource's `bucket` attribute resolves to
# `(known after apply)`, so we cannot match on `resource_changes.change.after`.
# Instead we walk `input.configuration.root_module.resources` and resolve the
# bucket reference via `expressions.bucket.references`, which preserves the
# unresolved Terraform reference expression (e.g. "aws_s3_bucket.data_bucket").
package main

import future.keywords.in

sse_type := "aws_s3_bucket_server_side_encryption_configuration"

deny[msg] {
	bucket := input.resource_changes[_]
	bucket.type == "aws_s3_bucket"
	bucket.change.actions[_] in ["create", "update"]

	not has_paired_encryption(bucket.address)

	msg := sprintf(
		"S3 bucket '%s' must have server-side encryption enabled",
		[bucket_label(bucket)],
	)
}

# True if some aws_s3_bucket_server_side_encryption_configuration resource in
# the plan's configuration references the bucket at `addr` (e.g. the
# `aws_s3_bucket.data_bucket` expression).
has_paired_encryption(addr) {
	enc := input.configuration.root_module.resources[_]
	enc.type == sse_type
	ref := enc.expressions.bucket.references[_]
	startswith(ref, addr)
}

bucket_label(change) := name {
	parts := split(change.address, ".")
	name := parts[count(parts) - 1]
}
