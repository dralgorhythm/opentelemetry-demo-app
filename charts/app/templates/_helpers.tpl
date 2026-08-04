{{/*
Two label sets, deliberately separate:

- app.selectorLabels: the Deployment selector and Service selector. FROZEN
  at `app: <release>` — selectors are immutable on a live Deployment, so
  this set must never grow.
- app.labels: metadata labels (mutable) — the standard k8s label set for
  tooling, wrapped around the selector labels.
*/}}

{{- define "app.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end }}

{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
