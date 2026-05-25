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

approved_registry_prefix := "123456789012.dkr.ecr.us-east-1.amazonaws.com/"

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
	not startswith(container.image, approved_registry_prefix)

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
