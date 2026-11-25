---
# Job Search Hub's WORKFLOW.md front matter as it stood before TP-1663: its server described in
# `verification.dev_server`, and run beside the Mac app on every QA pass by `dev_server: true`.
verification:
  enabled: false
  dev_server:
    build_cmd: server/scripts/dev-server.sh build
    start_cmd: server/scripts/dev-server.sh start
    health_check_url: http://127.0.0.1:8090/v1/health
    health_timeout_ms: 180000
auto_review:
  playbooks:
    macos_app:
      build: macos/scripts/build-app.sh
      app: macos/build/JobSearchHub.app
      dev_server: true
      dev_server_port: 8090
      requires: [go, pg_ctl, initdb, jq]
      launch_env:
        HUB_API_URL: "http://127.0.0.1:$SYMPHONY_VERIFICATION_PORT"
    android_app:
      build: android/gradlew -p android assembleDebug
      apk_path: android/app/build/outputs/apk/debug/app-debug.apk
      application_ids: [com.jobsearchhub.app]
---
Work on {{ issue.identifier }}.
