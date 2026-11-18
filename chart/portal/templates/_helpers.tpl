{{/*
_helpers.tpl — іменовані шаблони (named templates). Файли з "_" Helm не рендерить
як маніфести; тут лише `define`, які інші шаблони викликають через `include`.
Синтаксис:
  {{- ... -}}   дефіс прибирає пробіли/переноси рядка зліва/справа від тегу
  default A B   => B, якщо B не порожнє, інакше A
  trunc 63      => імена об'єктів і значення міток у Kubernetes обмежені 63 символами
  trimSuffix "-" прибирає дефіс у кінці після обрізання
*/}}

{{/*
portal.name — коротке ім'я застосунку (ім'я чарту або nameOverride).
Виклик: {{ include "portal.name" . }}
*/}}
{{- define "portal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
portal.fullname — базове ім'я всіх об'єктів, будується з .Release.Name.
  helm install portal ...  => "portal"   (ім'я релізу вже містить ім'я чарту)
  helm install demo ...    => "demo-portal"
Ніде в шаблонах ім'я релізу не пишемо вручну — лише через цей helper.
*/}}
{{- define "portal.fullname" -}}
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
portal.componentName — ім'я конкретного об'єкта: <fullname>-<component>.
Аргумент — словник (dict), бо include приймає лише ОДИН аргумент:
  {{ include "portal.componentName" (dict "root" $ "component" "api") }}  => portal-api
$ — завжди кореневий контекст (.Values, .Release, .Chart), навіть усередині range/with.
Для релізу "portal" імена збігаються з Lab 3: portal-api, portal-db, portal-config,
portal-secret, portal-db-data.
*/}}
{{- define "portal.componentName" -}}
{{- printf "%s-%s" (include "portal.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
portal.selectorLabels — НЕЗМІННІ мітки для selector (Deployment.spec.selector, Service.spec.selector).
Аргумент: (dict "root" $ "component" "api"). component розрізняє api / db / ...
*/}}
{{- define "portal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "portal.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
portal.labels — повний набір міток для metadata.labels усіх об'єктів.
Включає selectorLabels + службові мітки Helm. Аргумент такий самий, як у selectorLabels.
  quote      => бере значення в лапки (версія "1.0.0" має бути рядком)
  replace    => "+" недопустимий у значенні мітки
*/}}
{{- define "portal.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "portal.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Values.image.tag | default .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: portal-generator
{{- end }}
