{{/*
Common labels
*/}}
{{- define "storage-autoscaler.labels" -}}
app.kubernetes.io/name: storage-autoscaler
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "storage-autoscaler.selectorLabels" -}}
app.kubernetes.io/name: storage-autoscaler
{{- end }}
