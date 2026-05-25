# Lambda-specific guardrails.
#
# 1. Function timeout MUST be <= 300 seconds.
# 2. Production functions (Environment=prd) MUST have `kms_key_arn` set so
#    environment variables are encrypted with a customer-managed key.
package main

import future.keywords.in

max_timeout_seconds := 300

# ----- Timeout cap -------------------------------------------------------------

deny[msg] {
	change := input.resource_changes[_]
	change.type == "aws_lambda_function"
	change.change.actions[_] in ["create", "update"]

	timeout := change.change.after.timeout
	timeout > max_timeout_seconds

	msg := sprintf(
		"Lambda '%s' timeout %d exceeds maximum of %d seconds",
		[lambda_label(change), timeout, max_timeout_seconds],
	)
}

# ----- Prod must use a customer-managed KMS key --------------------------------

deny[msg] {
	change := input.resource_changes[_]
	change.type == "aws_lambda_function"
	change.change.actions[_] in ["create", "update"]

	change.change.after.tags.Environment == "prd"

	not change.change.after.kms_key_arn

	msg := sprintf(
		"Lambda '%s' in prd must set kms_key_arn (customer-managed key)",
		[lambda_label(change)],
	)
}

# ----- Helpers -----------------------------------------------------------------

lambda_label(change) := name {
	name := change.change.after.function_name
}

lambda_label(change) := name {
	not change.change.after.function_name
	parts := split(change.address, ".")
	name := parts[count(parts) - 1]
}
