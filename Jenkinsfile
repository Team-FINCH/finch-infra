// CD 파이프라인: master 머지 webhook → 변경 파트 감지 → 해당 이미지만 빌드 → compose up
//
// Jenkins job 설정(최초 1회):
//   - Pipeline from SCM 으로 이 파일을 지정 (branch: master)
//   - GitLab plugin 설치 후 webhook 연결: http://<공인IP>/jenkins/project/<job이름> (nginx 80 경유)
//   - Credentials 등록 (결정: 비밀값은 Jenkins Credentials 에 보관, 배포 시점에 주입)
//       finch-env     (Secret file) : infra/.env.example 을 채운 파일
//       finch-ai-env  (Secret file) : ai/.env.example 을 채운 파일
pipeline {
    agent any

    options {
        disableConcurrentBuilds()   // 배포가 겹치면 compose 가 서로를 덮어쓴다
        timestamps()
    }

    parameters {
        booleanParam(name: 'FORCE_ALL', defaultValue: false,
                     description: '변경 감지를 건너뛰고 전체 서비스를 빌드·배포')
    }

    environment {
        COMPOSE = 'docker compose -f infra/docker-compose.yml --env-file infra/.env'
    }

    stages {
        stage('변경 파트 감지') {
            steps {
                script {
                    // 직전 성공 빌드와 비교. 첫 빌드거나 강제 배포면 전체.
                    def all = ['backend', 'ai', 'nginx'] as Set
                    def services = [] as Set

                    if (params.FORCE_ALL || !env.GIT_PREVIOUS_SUCCESSFUL_COMMIT) {
                        services = all
                    } else {
                        def diff = sh(
                            script: "git diff --name-only ${env.GIT_PREVIOUS_SUCCESSFUL_COMMIT} HEAD",
                            returnStdout: true
                        ).trim()
                        diff.split('\n').each { f ->
                            if (f.startsWith('backend/') || f == 'infra/docker/backend.Dockerfile')
                                services << 'backend'
                            if (f.startsWith('ai/') || f == 'infra/docker/ai.Dockerfile')
                                services << 'ai'
                            // frontend 는 nginx 이미지 안에 정적 파일로 들어간다 (결정서 참고)
                            if (f.startsWith('frontend/') || f.startsWith('infra/nginx/')
                                    || f == 'infra/docker/frontend.Dockerfile')
                                services << 'nginx'
                            // 스택 정의 자체가 바뀌면 전체 재적용
                            if (f == 'infra/docker-compose.yml' || f == '.dockerignore')
                                services.addAll(all)
                        }
                    }

                    env.SERVICES = services.join(' ')
                    if (env.SERVICES) {
                        echo "배포 대상: ${env.SERVICES}"
                    } else {
                        echo '배포 대상 없음 (docs 등 인프라 무관 변경) — 이후 스테이지를 건너뛴다'
                    }
                }
            }
        }

        stage('비밀값 주입') {
            when { expression { env.SERVICES } }
            steps {
                withCredentials([
                    file(credentialsId: 'finch-env',    variable: 'ENV_FILE'),
                    file(credentialsId: 'finch-ai-env', variable: 'AI_ENV_FILE'),
                ]) {
                    sh 'cp "$ENV_FILE" infra/.env && cp "$AI_ENV_FILE" infra/ai.env'
                }
            }
        }

        stage('빌드') {
            when { expression { env.SERVICES } }
            steps {
                // 같은 VM 의 로컬 이미지 저장소에 생성 — 레지스트리 없음 (결정서 참고)
                sh "${COMPOSE} build ${env.SERVICES}"
            }
        }

        stage('배포') {
            when { expression { env.SERVICES } }
            steps {
                // 변경된 서비스 컨테이너만 교체 (수 초 다운타임 허용).
                // --wait: healthcheck 가 healthy 가 될 때까지 기다린다. 컨테이너가 뜨자마자
                // 죽는 배포가 '성공'으로 기록되는 것을 여기서 차단한다 (healthcheck 없는
                // 서비스는 기존처럼 started 기준).
                sh "${COMPOSE} up -d --wait ${env.SERVICES}"
                sh "${COMPOSE} ps"
            }
        }

        stage('스모크 테스트') {
            when { expression { env.SERVICES } }
            steps {
                // Jenkins 는 컨테이너라 localhost 가 호스트가 아니다 — 앱 네트워크(finch_default)에
                // 붙어 있으므로 컨테이너 이름으로 nginx 를 직접 부른다.
                // 프런트 정적 서빙과 backend 헬스를 실제 사용자 경로(nginx 경유)로 확인한다.
                sh 'curl -fsS -o /dev/null --retry 3 --retry-delay 3 http://finch-nginx/'
                sh 'curl -fsS --retry 3 --retry-delay 3 http://finch-nginx/api/actuator/health'
            }
        }
    }

    post {
        always {
            // 비밀값은 워크스페이스에 남기지 않는다
            sh 'rm -f infra/.env infra/ai.env'
        }
        failure {
            echo '배포 실패 — docker compose logs <서비스> 로 원인을 확인할 것'
            // TODO: Mattermost/Discord webhook 알림 연동
        }
    }
}
