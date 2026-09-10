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
        // helm·kubectl 을 돌릴 임시 컨테이너의 재료 (FINCH-135).
        // 왜 Jenkins 안에서 직접 부르지 않는지는 'k8s 배포' 스테이지 주석 참고.
        JENKINS_CONTAINER = 'finch-jenkins'
        JENKINS_IMAGE = 'finch/jenkins:latest'
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

        // 커트오버까지 compose 와 k8s 에 함께 배포한다 (FINCH-135).
        //
        // 트래픽은 아직 호스트 nginx(80·443)가 받으므로 여기서 helm 만 돌리면 운영이
        // 갱신되지 않은 채 남는다. 그래서 compose 배포를 지우지 않고 뒤에 덧붙인다.
        // compose 스모크가 통과한 뒤에 도는 순서라, k8s 가 실패해도 운영은 이미 정상이다.
        // FINCH-136 에서 80·443 을 넘긴 뒤에 compose 쪽을 뗀다.
        //
        // **when 을 걸지 않는다.** 차트만 고친 커밋은 SERVICES 를 세우지 않으므로
        // 게이트를 걸면 차트 변경이 영원히 배포되지 않는다 — 운영 스크립트 동기화
        // (FINCH-204)와 같은 함정이다.
        stage('k8s 배포') {
            steps {
                script {
                    // 태그는 그 파트를 마지막으로 건드린 커밋이다. 매 빌드의 HEAD 를 쓰면
                    // 문서만 고친 머지에도 파드 전체가 교체된다. 안 바뀐 파트는 태그가
                    // 그대로라 helm 이 차이를 못 찾고 파드를 건드리지 않는다.
                    //
                    // 경로 목록은 '변경 파트 감지' 와 같아야 한다. 어긋나면 이미지는
                    // 새로 빌드됐는데 태그가 그대로여서 k8s 가 옛 이미지를 계속 쓴다.
                    def parts = [
                        [name: 'backend',  image: 'finch/backend',
                         paths: 'backend/ infra/docker/backend.Dockerfile'],
                        [name: 'ai',       image: 'finch/ai',
                         paths: 'ai/ infra/docker/ai.Dockerfile'],
                        [name: 'frontend', image: 'finch/nginx',
                         paths: 'frontend/ infra/nginx/ infra/docker/frontend.Dockerfile'],
                    ]

                    // 클로저(.each) 안에서 sh 를 부르면 CPS 변환과 부딪힐 수 있다.
                    // 고전적인 for 문이 이 자리에서는 안전한 관용구다.
                    def sets = []
                    for (int i = 0; i < parts.size(); i++) {
                        def p = parts[i]
                        def tag = sh(script: "git log -1 --format=%h -- ${p.paths}",
                                     returnStdout: true).trim()
                        if (!tag) {
                            error "${p.name} 의 마지막 변경 커밋을 못 구했다. 경로 목록을 확인할 것: ${p.paths}"
                        }
                        // compose 가 빌드한 :latest 를 그 커밋 태그로도 가리킨다. 다시 빌드하지
                        // 않은 파트는 :latest 가 이미 그 커밋의 산출물이라 태그만 붙이면 된다.
                        sh "docker tag ${p.image}:latest ${p.image}:${tag}"
                        sets << "--set ${p.name}.image.tag=${tag}"
                        echo "${p.name} → ${p.image}:${tag}"
                    }

                    // --atomic: 실패하면 직전 리비전으로 되돌린다. 반쪽 배포로 멈추지 않게 한다.
                    //           --wait 을 포함하므로 readinessProbe 통과가 성공 판정이다.
                    helmExec("upgrade --install finch infra/k8s/charts/finch -n finch " +
                             "--atomic --timeout 5m ${sets.join(' ')}")
                    kubectlExec('-n finch get deploy -o wide')
                }
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

// helm·kubectl 을 임시 컨테이너에서 돌린다 (FINCH-135).
//
// Jenkins 컨테이너 안에서 직접 부르면 k8s API 서버에 닿지 못한다. ufw 가 docker0 과
// cni0 만 허용하는데(Testcontainers 때문에 넣은 규칙) Jenkins 는 compose 네트워크에
// 있어서 노드 IP·게이트웨이·클러스터 서비스 IP 가 전부 막힌다. 실측으로 확인했다.
//
// 기본 브리지에 컨테이너를 띄우면 그 규칙에 걸려 통과한다. Jenkins 가 이미 docker.sock
// 으로 이미지를 빌드하는 것과 같은 경로다 — 방화벽을 새로 열지 않아도 된다.
//
// --volumes-from: 워크스페이스가 같은 경로로 보여 경로 변환이 필요 없다.
// -w "$PWD":     helm 이 상대 경로를 저장소 이름으로 오해하는 것을 막는다.
// KUBECONFIG:    k3s 가 만든 파일의 server 는 127.0.0.1 이라 컨테이너에서 쓸 수 없다.
//                파일을 고치는 대신 --kube-apiserver 로 주소만 바꾼다. API 서버 인증서
//                SAN 에 노드 IP 가 있어 TLS 검증은 그대로 통과한다.
def k8sTool(String tool, String serverFlag, String args) {
    sh """
        docker run --rm --user root --volumes-from ${env.JENKINS_CONTAINER} -w "\$PWD" \\
          -v /etc/rancher/k3s/k3s.yaml:/kc:ro -e KUBECONFIG=/kc \\
          --entrypoint ${tool} ${env.JENKINS_IMAGE} \\
          ${serverFlag} "\$KUBE_APISERVER" ${args}
    """
}

def helmExec(String args) {
    k8sTool('helm', '--kube-apiserver', args)
}

def kubectlExec(String args) {
    k8sTool('kubectl', '--server', args)
}

// JSON 문자열 안에서 깨지는 것만 바꾼다. JsonOutput 을 쓰면 샌드박스에서 스크립트
// 승인이 필요해 파이프라인이 조용히 멈출 수 있으므로 String 메서드만 쓴다.
def jsonEscape(String s) {
    return (s ?: '')
        .replace('\\', '\\\\')
        .replace('"', '\\"')
        .replace('\r', '')
        .replace('\n', '\\n')
        .replace('\t', '\\t')
}

// 알림 전송은 배포 결과를 바꾸지 않는다. webhook 이 없거나 실패해도 빌드 판정은 그대로 둔다.
//
// 본문 형식은 관측 알림(FINCH-187 의 finch_notification)과 같은 다섯 줄이다.
// 같은 채널에 두 가지 모양이 섞이면 읽는 사람이 매번 형식을 다시 파악해야 한다.
def notifyDeploy(String state, String detail) {
    def services = env.SERVICES ?: '없음'
    def branch = env.GIT_BRANCH ?: 'master'
    def firing = (state == '실패')
    def stamp = new Date().format('yyyy-MM-dd HH:mm:ss', TimeZone.getTimeZone('Asia/Seoul'))
    def title = firing ? '[경보] 배포 실패' : '[복구] 배포 정상'
    def body = "상태  " + (firing ? '발생' : '해소') + "\n" +
               "증상  ${detail}\n" +
               "조치  ${env.BUILD_URL}console\n" +
               "대상  ${services} (${branch} #${env.BUILD_NUMBER})\n" +
               "시각  ${stamp}"

    // Mattermost 의 Incoming Webhook 은 Slack 호환 페이로드를 받는다. Discord 는
    // 첨부를 이해하지 못하므로 평문으로 떨어뜨린다.
    def payload
    if (env.NOTIFY_KIND == 'discord') {
        payload = '{"content":"' + jsonEscape(title + "\n" + body) + '"}'
    } else {
        payload = '{"username":"Finch 배포","icon_emoji":":rocket:","attachments":[{' +
                  '"color":"' + (firing ? '#D63232' : '#36A64F') + '",' +
                  '"title":"' + jsonEscape(title) + '",' +
                  '"fallback":"' + jsonEscape(title) + '",' +
                  '"text":"' + jsonEscape(body) + '"}]}'
    }

    try {
        withCredentials([string(credentialsId: 'finch-notify-webhook', variable: 'NOTIFY_HOOK')]) {
            writeFile file: '.notify.json', text: payload
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
