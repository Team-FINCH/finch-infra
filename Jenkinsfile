// CD 파이프라인: master 머지 webhook → 변경 파트 감지 → 해당 이미지만 빌드 → compose up
//
// Jenkins job 설정(최초 1회):
//   - Pipeline from SCM 으로 이 파일을 지정 (branch: master)
//   - GitLab plugin 설치 후 webhook 연결: https://finchapp.org/jenkins/project/<job이름>
//     (nginx 443 종단 경유. GitLab webhook 은 리다이렉트를 따라가지 않으므로 https 로 등록해야 한다)
//   - Credentials 등록 (결정: 비밀값은 Jenkins Credentials 에 보관, 배포 시점에 주입)
//       finch-env             (Secret file) : infra/.env.example 을 채운 파일
//       finch-ai-env          (Secret file) : ai/.env.example 을 채운 파일
//       finch-kakaopay-secret (Secret text) : 카카오페이 Secret Key. 아래 '비밀값 주입' 이
//         infra/.env 에 한 줄로 덧붙인다. Secret file 은 내용을 다시 볼 수 없어 한 줄 추가에도
//         파일 전체 교체가 필요하므로, 나중에 추가된 값은 Secret text 로 분리한다 (FINCH-159)
//       finch-extra-env       (Secret file) : 위와 같은 이유로 나중에 추가된 backend 비밀값을
//         모아 둔다. KEY=VALUE 를 줄마다 적은 파일이고 infra/.env 뒤에 그대로 이어 붙인다
//         (FINCH-173). 값을 더 넣을 때는 새 credential 을 만들지 말고 이 파일에 줄을 더한다.
//         Secret text 가 아닌 이유: plain-credentials 의 Secret text 는 <f:password/> 한 줄
//         입력이라 여러 줄을 붙여넣으면 개행이 잘린다 (플러그인 jelly 확인). 파일은 그대로 보존된다
//       finch-ai-extra-env    (Secret file) : 같은 역할의 AI 쪽. infra/ai.env 뒤에 이어 붙인다.
//         ai 서비스는 compose 에서 env_file: ai.env 를 쓰므로 줄이 늘면 그대로 컨테이너에 들어간다
//       finch-notify-webhook  (Secret text) : 배포 알림 webhook URL. 없으면 알림만 건너뛴다
//     알림 채널 형식은 아래 NOTIFY_KIND 로 고른다 (mattermost | discord)
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
        NOTIFY_KIND = 'mattermost'
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
                        echo '배포 대상 없음 (docs 등 인프라 무관 변경) — 컨테이너 관련 스테이지를 건너뛴다'
                    }
                }
            }
        }

        // cron 이 실행하는 운영 스크립트를 갱신한다 (FINCH-204).
        //
        // **when 을 걸지 않는다.** 변경 감지는 컨테이너를 다시 만들지 판단하는 것이고,
        // infra/scripts/ 만 고친 커밋은 SERVICES 를 세우지 않는다. 여기에 게이트를 걸면
        // 스크립트만 바뀐 배포에서 이 스테이지가 건너뛰어지고, 그러면 지금 고치는 문제가
        // 그대로 재현된다 — 머지는 됐는데 서버가 옛 파일을 계속 실행한다.
        stage('운영 스크립트 동기화') {
            steps {
                sh '''
                    set -e

                    # 마운트가 없으면 조용히 넘어가지 않고 실패한다. 이 스테이지의 존재 이유가
                    # "갱신되지 않는 것을 모르고 지나가는 상태"를 없애는 것이라, 마운트 누락을
                    # 성공으로 넘기면 스테이지를 넣은 의미가 사라진다.
                    if [ ! -d /opt/ops ]; then
                        echo "✗ /opt/ops 가 없다. docker-compose.infra.yml 의 jenkins 바인드 마운트를 확인할 것" >&2
                        echo "  마운트 추가 후에는 jenkins 컨테이너를 다시 만들어야 적용된다" >&2
                        exit 1
                    fi

                    mkdir -p /opt/ops/scripts /opt/ops/k8s
                    cp -a infra/scripts/. /opt/ops/scripts/
                    cp -a infra/k8s/.     /opt/ops/k8s/

                    # cron 은 스크립트를 직접 실행하므로 실행 권한이 필요하다.
                    find /opt/ops/scripts /opt/ops/k8s -name '*.sh' -exec chmod +x {} +

                    echo "▶ 운영 스크립트 동기화 완료"
                    md5sum /opt/ops/scripts/renew-cert.sh infra/scripts/renew-cert.sh
                '''
            }
        }

        stage('비밀값 주입') {
            when { expression { env.SERVICES } }
            steps {
                withCredentials([
                    file(credentialsId: 'finch-env',    variable: 'ENV_FILE'),
                    file(credentialsId: 'finch-ai-env', variable: 'AI_ENV_FILE'),
                    string(credentialsId: 'finch-kakaopay-secret', variable: 'KAKAOPAY_SECRET'),
                    file(credentialsId: 'finch-extra-env',    variable: 'EXTRA_ENV_FILE'),
                    file(credentialsId: 'finch-ai-extra-env', variable: 'AI_EXTRA_ENV_FILE'),
                ]) {
                    // set +x: Jenkins 의 sh 는 기본이 -x 라 확장된 명령이 콘솔에 찍힌다.
                    // 앞줄 개행을 붙이는 이유는 Secret file 이 개행으로 끝나지 않을 수 있어서다.
                    sh '''
                        set +x
                        cp "$ENV_FILE" infra/.env
                        cp "$AI_ENV_FILE" infra/ai.env
                        printf '\\nKAKAOPAY_SECRET_KEY=%s\\n' "$KAKAOPAY_SECRET" >> infra/.env
                        printf '\\n' >> infra/.env
                        cat "$EXTRA_ENV_FILE" >> infra/.env
                        printf '\\n' >> infra/ai.env
                        cat "$AI_EXTRA_ENV_FILE" >> infra/ai.env
                    '''
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
                // 붙어 있으므로 컨테이너 이름으로 직접 부른다.
                // 프런트는 실제 사용자 경로(nginx 경유)로, backend 헬스는 컨테이너 직접 호출로 확인한다.
                // (actuator 는 /api 아래가 아니라 루트에 있어 nginx 경유로는 404 — EC2 실측.
                //  nginx 에 actuator 를 노출하는 것은 관리 엔드포인트 공개라 하지 않는다)
                sh 'curl -fsS -o /dev/null --retry 3 --retry-delay 3 http://finch-nginx/'
                sh 'curl -fsS --retry 3 --retry-delay 3 http://finch-backend:8080/actuator/health'
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
            script { notifyDeploy('실패', '배포가 실패했다. 서버는 이전 상태로 남아 있다.') }
        }
        fixed {
            script { notifyDeploy('복구', '이전 실패 이후 배포가 다시 성공했다.') }
        }
    }
}

// 알림 전송은 배포 결과를 바꾸지 않는다. webhook 이 없거나 실패해도 빌드 판정은 그대로 둔다.
def notifyDeploy(String state, String detail) {
    def services = env.SERVICES ?: '없음'
    def branch = env.GIT_BRANCH ?: 'master'
    def msg = "[Finch 배포 ${state}] ${env.JOB_NAME} #${env.BUILD_NUMBER}" +
              "\\n브랜치: ${branch} / 대상: ${services}" +
              "\\n${detail}" +
              "\\n${env.BUILD_URL}console"
    def field = (env.NOTIFY_KIND == 'discord') ? 'content' : 'text'

    try {
        withCredentials([string(credentialsId: 'finch-notify-webhook', variable: 'NOTIFY_HOOK')]) {
            writeFile file: '.notify.json', text: "{\"${field}\":\"${msg}\"}"
            def rc = sh(returnStatus: true, script:
                'curl -fsS -m 10 -X POST -H "Content-Type: application/json" ' +
                '--data @.notify.json "$NOTIFY_HOOK" -o /dev/null')
            if (rc != 0) {
                echo "알림 전송 실패 (curl exit ${rc}) — 배포 판정에는 영향 없음"
            }
        }
    } catch (err) {
        echo "알림 건너뜀: ${err.message}"
    } finally {
        sh 'rm -f .notify.json'
    }
}
