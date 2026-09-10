# Jenkins + docker CLI + kubectl + helm.
# 호스트의 /var/run/docker.sock 을 마운트해 호스트 Docker 로 빌드한다.
# → 빌드된 이미지가 곧바로 호스트 로컬 저장소에 생겨 레지스트리가 필요 없다 (결정서 참고).
#   k3s 도 같은 docker 를 런타임으로 쓰므로(container-runtime: docker://) 그 이미지를
#   그대로 본다. imagePullPolicy 가 IfNotPresent 라 push 없이 배포된다.
#
# 베이스를 lts 가 아니라 정확한 버전으로 고정한다. lts 는 움직이는 태그라
# 재빌드 시점에 따라 다른 Jenkins 가 나오고, 그때 플러그인 호환이 깨져도
# 무엇이 바뀌었는지 남지 않는다.
FROM jenkins/jenkins:2.568.2-lts-jdk21

USER root

# ── docker CLI ───────────────────────────────────────────
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# ── kubectl 과 helm ──────────────────────────────────────
# FINCH-135 로 배포 스테이지가 helm 을 부른다. 둘 다 컨테이너에 없어서
# 그 작업의 선행 조건이다.
#
# kubectl 은 클러스터(k3s v1.36.4)와 마이너 버전을 맞춘다. 두 단계 이상 벌어지면
# 지원 범위 밖이다.
#
# 체크섬을 박는다. 받아서 바로 실행 권한을 주는 경로라 내용이 바뀌어도 알 방법이 없다.
ARG KUBECTL_VERSION=v1.36.4
ARG KUBECTL_SHA256=8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a
ARG HELM_VERSION=v3.16.2
ARG HELM_SHA256=9318379b847e333460d33d291d4c088156299a26cd93d570a7f5d0c36e50b5bb

RUN set -eux; \
    curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c -; \
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
    curl -fsSL -o /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"; \
    echo "${HELM_SHA256}  /tmp/helm.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/helm.tar.gz -C /tmp linux-amd64/helm; \
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm; \
    rm -rf /tmp/kubectl /tmp/helm.tar.gz /tmp/linux-amd64; \
    kubectl version --client=true; \
    helm version --short

# ── 플러그인 ─────────────────────────────────────────────
# 지금까지는 UI 로 설치해 jenkins_home 볼륨에만 있었다. 볼륨이 날아가면 94개를
# 손으로 다시 깔아야 하고 버전 기록이 어디에도 없다.
#
# jenkins-plugin-cli 는 /usr/share/jenkins/ref/plugins 에 넣고, Jenkins 는 기동 때
# jenkins_home 에 없는 것만 복사한다. 그래서 이 변경이 지금 볼륨의 플러그인을
# 덮어쓰거나 되돌리지 않는다 — 빈 볼륨에서 다시 세울 수 있게 되는 것이 목적이다.
COPY infra/docker/jenkins-plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# docker.sock 권한 문제를 피하려고 compose 에서 user: root 로 실행한다 (README 참고).
