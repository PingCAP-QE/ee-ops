{{/*
Expand the name of the chart.
*/}}
{{- define "prow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "prow.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}


{{/*
full name for component crier
*/}}
{{- define "prow.fullname.crier" -}}
{{ include "prow.fullname" . }}-crier
{{- end }}

{{/*
full name for component deck
*/}}
{{- define "prow.fullname.deck" -}}
{{ include "prow.fullname" . }}-deck
{{- end }}

{{/*
full name for component ghproxy
*/}}
{{- define "prow.fullname.ghproxy" -}}
{{ include "prow.fullname" . }}-ghproxy
{{- end }}

{{/*
full name for component hook
*/}}
{{- define "prow.fullname.hook" -}}
{{ include "prow.fullname" . }}-hook
{{- end }}

{{/*
full name for component horologium
*/}}
{{- define "prow.fullname.horologium" -}}
{{ include "prow.fullname" . }}-horologium
{{- end }}

{{/*
full name for component pcm
*/}}
{{- define "prow.fullname.pcm" -}}
{{ include "prow.fullname" . }}-pcm
{{- end }}

{{/*
full name for component sinker
*/}}
{{- define "prow.fullname.sinker" -}}
{{ include "prow.fullname" . }}-sinker
{{- end }}

{{/*
full name for component statusReconciler
*/}}
{{- define "prow.fullname.statusReconciler" -}}
{{ include "prow.fullname" . }}-status-reconciler
{{- end }}

{{/*
full name for component tide
*/}}
{{- define "prow.fullname.tide" -}}
{{ include "prow.fullname" . }}-tide
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "prow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "prow.labels" -}}
helm.sh/chart: {{ include "prow.chart" . }}
{{ include "prow.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels for crier
*/}}
{{- define "prow.labels.crier" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: crier
{{- end }}

{{/*
Labels for deck
*/}}
{{- define "prow.labels.deck" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: deck
{{- end }}

{{/*
Labels for ghproxy
*/}}
{{- define "prow.labels.ghproxy" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: ghproxy
{{- end }}

{{/*
Labels for hook
*/}}
{{- define "prow.labels.hook" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: hook
{{- end }}

{{/*
Labels for horologium
*/}}
{{- define "prow.labels.horologium" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: horologium
{{- end }}

{{/*
Labels for pcm
*/}}
{{- define "prow.labels.pcm" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: pcm
{{- end }}

{{/*
Labels for sinker
*/}}
{{- define "prow.labels.sinker" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: sinker
{{- end }}

{{/*
Labels for status-reconciler
*/}}
{{- define "prow.labels.statusReconciler" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: statusReconciler
{{- end }}

{{/*
Labels for tide
*/}}
{{- define "prow.labels.tide" -}}
{{ include "prow.labels" . }}
app.kubernetes.io/app: tide
{{- end }}

{{/*
Common Selector labels
*/}}
{{- define "prow.selectorLabels" -}}
app.kubernetes.io/part-of: {{ include "prow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ .Chart.Name }}
{{- end }}

{{/*
Selector labels for crier
*/}}
{{- define "prow.selectorLabels.crier" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: crier
{{- end }}

{{/*
Selector labels for deck
*/}}
{{- define "prow.selectorLabels.deck" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: deck
{{- end }}

{{/*
Selector labels for ghproxy
*/}}
{{- define "prow.selectorLabels.ghproxy" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: ghproxy
{{- end }}

{{/*
Selector labels for hook
*/}}
{{- define "prow.selectorLabels.hook" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: hook
{{- end }}

{{/*
Selector labels for horologium
*/}}
{{- define "prow.selectorLabels.horologium" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: horologium
{{- end }}

{{/*
Selector labels for pcm
*/}}
{{- define "prow.selectorLabels.pcm" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: pcm
{{- end }}

{{/*
Selector labels for sinker
*/}}
{{- define "prow.selectorLabels.sinker" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: sinker
{{- end }}

{{/*
Selector labels for statusReconciler
*/}}
{{- define "prow.selectorLabels.statusReconciler" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: statusReconciler
{{- end }}

{{/*
Selector labels for tide
*/}}
{{- define "prow.selectorLabels.tide" -}}
{{ include "prow.selectorLabels" . }}
app.kubernetes.io/app: tide
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "prow.serviceAccountName.crier" -}}
{{- if .Values.crier.serviceAccount.create }}
{{- default (include "prow.fullname.crier" .) .Values.crier.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.crier.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.deck" -}}
{{- if .Values.deck.serviceAccount.create }}
{{- default (include "prow.fullname.deck" .) .Values.deck.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.deck.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.hook" -}}
{{- if .Values.hook.serviceAccount.create }}
{{- default (include "prow.fullname.hook" .) .Values.hook.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.hook.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.horologium" -}}
{{- if .Values.horologium.serviceAccount.create }}
{{- default (include "prow.fullname.horologium" .) .Values.horologium.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.horologium.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.pcm" -}}
{{- if .Values.pcm.serviceAccount.create }}
{{- default (include "prow.fullname.pcm" .) .Values.pcm.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.pcm.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.sinker" -}}
{{- if .Values.sinker.serviceAccount.create }}
{{- default (include "prow.fullname.sinker" .) .Values.sinker.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.sinker.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.statusReconciler" -}}
{{- if .Values.statusReconciler.serviceAccount.create }}
{{- default (include "prow.fullname.statusReconciler" .) .Values.statusReconciler.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.statusReconciler.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "prow.serviceAccountName.tide" -}}
{{- if .Values.tide.serviceAccount.create }}
{{- default (include "prow.fullname.tide" .) .Values.tide.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.tide.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the role
*/}}
{{- define "prow.roleName.crier" -}}
{{- if .Values.crier.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.crier" .) .Values.crier.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.deck" -}}
{{- if .Values.deck.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.deck" .) .Values.deck.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.hook" -}}
{{- if .Values.hook.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.hook" .) .Values.hook.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.horologium" -}}
{{- if .Values.horologium.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.horologium" .) .Values.horologium.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.pcm" -}}
{{- if .Values.pcm.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.pcm" .) .Values.pcm.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.sinker" -}}
{{- if .Values.sinker.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.sinker" .) .Values.sinker.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.statusReconciler" -}}
{{- if .Values.statusReconciler.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.statusReconciler" .) .Values.statusReconciler.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleName.tide" -}}
{{- if .Values.tide.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.tide" .) .Values.tide.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the role binding
*/}}

{{- define "prow.roleBindingName.crier" -}}
{{- if .Values.crier.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.crier" .) .Values.crier.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.deck" -}}
{{- if .Values.deck.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.deck" .) .Values.deck.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.hook" -}}
{{- if .Values.hook.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.hook" .) .Values.hook.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.horologium" -}}
{{- if .Values.horologium.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.horologium" .) .Values.horologium.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.pcm" -}}
{{- if .Values.pcm.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.pcm" .) .Values.pcm.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.sinker" -}}
{{- if .Values.sinker.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.sinker" .) .Values.sinker.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.statusReconciler" -}}
{{- if .Values.statusReconciler.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.statusReconciler" .) .Values.statusReconciler.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}

{{- define "prow.roleBindingName.tide" -}}
{{- if .Values.tide.serviceAccount.roleBinding.create }}
{{- default (include "prow.fullname.tide" .) .Values.tide.serviceAccount.roleBinding.name }}
{{- end }}
{{- end }}
