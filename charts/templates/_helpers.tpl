{{/*
Expand the name of the chart.
*/}}
{{- define "nr-bqs-knox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
by the kube-dashboard.
*/}}
{{- define "nr-bqs-knox.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "nr-bqs-knox.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "nr-bqs-knox.labels" -}}
helm.sh/chart: {{ include "nr-bqs-knox.chart" . }}
{{ include "nr-bqs-knox.selectorLabels" . }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "nr-bqs-knox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nr-bqs-knox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Create the name of the service account to use.
*/}}
{{- define "nr-bqs-knox.serviceAccountName" -}}
{{- default (include "nr-bqs-knox.fullname" .) .Values.serviceAccountName -}}
{{- end -}}

{{/*
The full image reference, pulled from GitHub Container Registry.
*/}}
{{- define "nr-bqs-knox.image" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.image.repository -}}
{{- if .Values.image.tag -}}
{{- printf "%s/%s:%s" $registry $repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s/%s@%s" $registry $repository .Values.image.digest -}}
{{- end -}}
{{- end -}}
