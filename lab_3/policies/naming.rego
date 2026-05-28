# S3 bucket naming convention.
#
# Required pattern: client-{env}-{app}-{purpose}
#   env     in (dev, stg, prd)
#   app     lowercase letters and digits (e.g. lab3, myapp, billing2)
#   purpose lowercase letters, digits, hyphens (e.g. data, alice, my-team)
#
# Example of a compliant name: client-dev-lab3-data
# Example with a per-student suffix: client-dev-lab3-alice
package main

import future.keywords.in

bucket_name_pattern := `^client-(dev|stg|prd)-[a-z0-9]+-[a-z0-9-]+$`

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
