# Kubernetes / Amazon EKS workload guardrails.
#
# Applied to Kubernetes manifests (e.g. kubernetes/deployment.yaml) — not to
# the Terraform plan. Conftest selects this policy based on the `package main`
# declaration; the input shape is the YAML document for the manifest.
#
# Rules:
#   1. Every Deployment MUST carry the `environment` and `owner` labels on
#      its top-level metadata.
#   2. Every container image MUST come from the approved Amazon ECR registry.
#   3. Every container MUST declare both memory and CPU limits.
package main

import future.keywords.in

# Approved registry: per-account Amazon ECR only.
#
# Pattern: <account-id>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
#
# The policy enforces "image must be in YOUR private ECR" -- students mirror
# upstream images into their own ECR via docker pull / tag / push before
# deploying. This is the SYF production workflow: nothing pulls from
# Docker Hub or other public registries at runtime; all images go through
# the controlled per-account ECR boundary.
#
# The regex does NOT pin to a specific account -- each student has their
# own account and the lab fixtures must work in any of them.
approved_registry_regex := `^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/`

required_deployment_labels := ["environment", "owner"]

# ----- Required labels on Deployments ------------------------------------------

deny[msg] {
	input.kind == "Deployment"
	label := required_deployment_labels[_]
	not input.metadata.labels[label]

	msg := sprintf(
		"Deployment '%s' missing required label: %s",
		[input.metadata.name, label],
	)
}

# ----- Approved container image registry ---------------------------------------

deny[msg] {
	input.kind == "Deployment"
	container := input.spec.template.spec.containers[_]
	not regex.match(approved_registry_regex, container.image)

	msg := sprintf(
		"Container '%s' uses image from unapproved registry '%s'",
		[container.name, image_registry(container.image)],
	)
}

# ----- Resource limits ---------------------------------------------------------

deny[msg] {
	input.kind == "Deployment"
	container := input.spec.template.spec.containers[_]
	not container.resources.limits.memory

	msg := sprintf(
		"Container '%s' must have memory limit defined",
		[container.name],
	)
}

deny[msg] {
	input.kind == "Deployment"
	container := input.spec.template.spec.containers[_]
	not container.resources.limits.cpu

	msg := sprintf(
		"Container '%s' must have CPU limit defined",
		[container.name],
	)
}

# ----- Helpers -----------------------------------------------------------------

# Extract the registry hostname from an image string. For "docker.io/foo:bar"
# this returns "docker.io"; for a bare "nginx:latest" it returns "docker.io"
# (Docker's implicit default).
image_registry(image) := registry {
	contains(image, "/")
	parts := split(image, "/")
	registry := parts[0]
}

image_registry(image) := "docker.io" {
	not contains(image, "/")
}
