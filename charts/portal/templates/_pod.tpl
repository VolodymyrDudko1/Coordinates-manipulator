{{- /*
portal.apiPodTemplate — шаблон pod-а portal-api (metadata + spec), спільний для
Deployment (deployment.yaml, Lab 5) і Rollout (rollout.yaml, Lab 6), щоб pod-и були однакові.
Виклик: {{- include "portal.apiPodTemplate" . | nindent 4 }}  (після рядка "template:")
*/}}
{{- define "portal.apiPodTemplate" -}}
metadata:
  labels:
    {{- include "portal.labels" (dict "root" $ "component" "api") | nindent 4 }}
  annotations:
    # $.Template.BasePath = "<chart>/templates"; print склеює шлях до файлу ConfigMap.
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- if not .Values.secrets.existingSecret }}
    checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:           # потрібен, лише якщо пакет у GHCR приватний
    {{- toYaml . | nindent 4 }}
  {{- end }}
  terminationGracePeriodSeconds: 30
  containers:
    - name: portal-api
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.containerPort }}
      envFrom:                # усі ключі ConfigMap і Secret => змінні оточення
        - configMapRef:
            name: {{ include "portal.componentName" (dict "root" $ "component" "config") }}
        - secretRef:
            name: {{ include "portal.secretName" . }}
      env:
        # $(VAR) підставляє kubelet (не Helm!) з уже визначених змінних envFrom.
        {{- with .Values.failRate }}
        # Lab 7: частка відповідей 500 «поганої» версії. У spec pod-а (а не в спільному ConfigMap),
        # тому впливає лише на pod-и нової ревізії Rollout, а stable-pod-и працюють як раніше.
        - name: FAIL_RATE
          value: {{ . | quote }}
        {{- end }}
        - name: DATABASE_URL
          value: "postgresql+asyncpg://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(POSTGRES_DB)"
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      readinessProbe:         # /ready перевіряє з'єднання з БД
        httpGet:
          path: /ready
          port: http
        initialDelaySeconds: 5
        periodSeconds: 5
        timeoutSeconds: 2
        failureThreshold: 3
      livenessProbe:          # /health не залежить від БД
        httpGet:
          path: /health
          port: http
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
      lifecycle:
        preStop:
          exec:
            command: ["sleep", "5"]
{{- end }}
