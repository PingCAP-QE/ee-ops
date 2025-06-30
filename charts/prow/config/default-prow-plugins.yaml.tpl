plugins:
  {{- if .Values.prow.githubOrg }}
  {{ .Values.prow.githubOrg }}:
    plugins:
      - approve
      - assign
      - blunderbuss
      - cat
      - dog
      - help
      - heart
      - hold
      - label
      - lgtm
      - trigger
      - verify-owners
      - wip
      - yuks
  {{- end }}
