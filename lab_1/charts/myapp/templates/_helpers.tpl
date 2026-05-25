{{/*
Expand the name of the chart.
*/}}
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a fully qualified app name.
Used by `helm install` for default resource names.
*/}}
{{- define "myapp.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Common labels applied to every object in the chart.
*/}}
{{- define "myapp.labels" -}}
app: {{ include "myapp.name" . }}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
environment: {{ .Values.environment | default "base" }}
{{- end -}}

{{/*
Selector labels — the subset that goes into spec.selector.matchLabels.
Must NOT change across deployments or the Deployment will be unable to manage
its own pods.
*/}}
{{- define "myapp.selectorLabels" -}}
app: {{ include "myapp.name" . }}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Resolve the ServiceAccount name. Use the override if provided; otherwise
fall back to the fullname.
*/}}
{{- define "myapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "myapp.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
