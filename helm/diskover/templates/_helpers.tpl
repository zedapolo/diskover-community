{{- define "diskover.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 50 | trimSuffix "-" -}}
{{- else if .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name .Values.nameOverride | trunc 50 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "diskover.labels" -}}
app.kubernetes.io/name: diskover
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Image diskover-web :
- Priorité à .Values.web.image.repository
- Sinon si build.enabled=true, ImageStream local <fullname>-web:latest
- Sinon erreur claire
*/}}
{{- define "diskover.webImage" -}}
{{- if and .Values.web.image .Values.web.image.repository -}}
{{- printf "%s:%s" .Values.web.image.repository (.Values.web.image.tag | default .Chart.AppVersion) -}}
{{- else if .Values.build.enabled -}}
{{- printf "%s-web:latest" (include "diskover.fullname" .) -}}
{{- else -}}
{{- fail "web.image.repository est obligatoire lorsque build.enabled=false" -}}
{{- end -}}
{{- end -}}

{{/*
Image diskover-scanner :
- Priorité à .Values.scanner.image.repository
- Sinon si build.enabled=true, ImageStream local <fullname>-scanner:latest
- Sinon erreur claire
*/}}
{{- define "diskover.scannerImage" -}}
{{- if and .Values.scanner.image .Values.scanner.image.repository -}}
{{- printf "%s:%s" .Values.scanner.image.repository (.Values.scanner.image.tag | default .Chart.AppVersion) -}}
{{- else if .Values.build.enabled -}}
{{- printf "%s-scanner:latest" (include "diskover.fullname" .) -}}
{{- else -}}
{{- fail "scanner.image.repository est obligatoire lorsque build.enabled=false" -}}
{{- end -}}
{{- end -}}

{{- define "diskover.esHost" -}}
{{- if .Values.elasticsearch.create -}}
{{- printf "%s-es-http" .Values.elasticsearch.name -}}
{{- else -}}
{{- required "elasticsearch.host est obligatoire quand elasticsearch.create=false" .Values.elasticsearch.host -}}
{{- end -}}
{{- end -}}

{{- define "diskover.esSecretName" -}}
{{- if .Values.elasticsearch.create -}}
{{- printf "%s-es-elastic-user" .Values.elasticsearch.name -}}
{{- else -}}
{{- required "elasticsearch.userSecret.name est obligatoire quand elasticsearch.create=false" .Values.elasticsearch.userSecret.name -}}
{{- end -}}
{{- end -}}

{{- define "diskover.esSecretKey" -}}
{{- if .Values.elasticsearch.create -}}elastic{{- else -}}{{ .Values.elasticsearch.userSecret.key }}{{- end -}}
{{- end -}}

{{/* Variables d'environnement lues nativement par diskover (python) et diskover-web (php) */}}
{{- define "diskover.esEnv" -}}
- name: ES_HOST
  value: {{ include "diskover.esHost" . | quote }}
- name: ES_PORT
  value: {{ .Values.elasticsearch.port | toString | quote }}
- name: ES_USER
  value: {{ .Values.elasticsearch.user | quote }}
- name: ES_PASS
  valueFrom:
    secretKeyRef:
      name: {{ include "diskover.esSecretName" . }}
      key: {{ include "diskover.esSecretKey" . }}
- name: ES_HTTPS
  value: {{ ternary "true" "false" .Values.elasticsearch.tls | quote }}
- name: ES_SSLVERIFICATION
  value: {{ ternary "true" "false" .Values.elasticsearch.sslVerification | quote }}
{{- end -}}

{{/* Nom du ConfigMap d'identités (passwd / group) */}}
{{- define "diskover.identitiesConfigMap" -}}
{{- if .Values.identities.configMapName -}}
{{- .Values.identities.configMapName -}}
{{- else -}}
{{- printf "%s-identities" (include "diskover.fullname" .) -}}
{{- end -}}
{{- end -}}
