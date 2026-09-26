{{/*
---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
---------------------------------------------------------------------------
*/}}

{{/*
Resource base name. Defaults to the release name so a fresh install gets a
sane name for free, but every values-*.yaml in this repo pins
nameOverride to "metrics-dashboard" so existing live objects (Deployment/
Secret keep the current name) are matched exactly — this chart is meant to
be a drop-in replacement for the raw k8s/ manifests, not a rename.
*/}}
{{- define "metrics-dashboard.name" -}}
{{- .Values.nameOverride | default .Chart.Name -}}
{{- end -}}

{{- define "metrics-dashboard.fullname" -}}
{{- .Values.fullnameOverride | default (include "metrics-dashboard.name" .) -}}
{{- end -}}

{{- define "metrics-dashboard.configMapName" -}}
{{- .Values.configMap.name | default (printf "%s-config" (include "metrics-dashboard.fullname" .)) -}}
{{- end -}}

{{- define "metrics-dashboard.secretName" -}}
{{- if .Values.secret.existingSecretName -}}
{{- .Values.secret.existingSecretName -}}
{{- else -}}
{{- .Values.secret.name | default "dashboard-auth" -}}
{{- end -}}
{{- end -}}

{{- define "metrics-dashboard.labels" -}}
app: {{ .Values.podLabel | default "dashboard" }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "metrics-dashboard.selectorLabels" -}}
app: {{ .Values.podLabel | default "dashboard" }}
{{- end -}}
