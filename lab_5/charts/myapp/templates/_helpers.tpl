{{/*
Chart name.
*/}}
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every object in the chart.
NOTE: deliberately does NOT include `color` — color is per-Deployment.
*/}}
{{- define "myapp.labels" -}}
app: {{ include "myapp.name" . }}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Shared DB / region / IRSA environment for both colors. Pass the color string in
via `dict "ctx" . "color" "blue|version"` ... actually we render color-specific
env inline in each Deployment; this helper carries only the common vars.
*/}}
{{- define "myapp.dbEnv" -}}
- name: DB_SECRET_NAME
  value: {{ .Values.db.secretName | quote }}
- name: DB_HOST
  value: {{ .Values.db.host | quote }}
- name: DB_NAME
  value: {{ .Values.db.name | quote }}
- name: AWS_REGION
  value: {{ .Values.region | quote }}
{{- end -}}
