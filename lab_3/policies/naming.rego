# S3 bucket naming convention.
#
# Required pattern: client-{env}-{app}-{purpose}
#   env     in (dev, stg, prd)
#   app     lowercase letters
#   purpose lowercase letters, digits, hyphens
#
# Example of a compliant name: client-dev-lab3-data
package main

import future.keywords.in

bucket_name_pattern := `^client-(dev|stg|prd)-[a-z]+-[a-z0-9-]+$`

deny[msg] {
	change := input.resource_changes[_]
	change.type == "aws_s3_bucket"
	change.change.actions[_] in ["create", "update"]

	name := change.change.after.bucket
	not regex.match(bucket_name_pattern, name)

	msg := sprintf(
		"S3 bucket '%s' does not match naming pattern 'client-{env}-{app}-{purpose}'",
		[name],
	)
}
