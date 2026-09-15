{{/*
Общие лейблы, стандартный набор рекомендуемых Helm/k8s-лейблов.
*/}}
{{- define "adminpanel.labels" -}}
app.kubernetes.io/part-of: nrd-business-panel
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "adminpanel.namespace" -}}
{{ .Values.namespace.name }}
{{- end -}}
