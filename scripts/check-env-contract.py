#!/usr/bin/env python3
"""application.yaml 의 환경변수 계약과, 그것을 주입하는 두 배포 경로를 대조한다.

  compose 경로  infra/docker-compose.yml         (현재 운영)
  차트 경로     infra/k8s/charts/finch/...       (커트오버 후 운영)

한쪽만 지키면 커트오버 때 같은 누락이 재연된다.
배경과 판정 기준은 infra/README.md 의 '환경변수 계약 검사' 절에 있다.
사용법: python3 infra/scripts/check-env-contract.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_YAML = os.path.join(ROOT, "backend", "src", "main", "resources", "application.yaml")
COMPOSE = os.path.join(ROOT, "infra", "docker-compose.yml")
CHART = os.path.join(ROOT, "infra", "k8s", "charts", "finch", "templates", "backend.yaml")
CHART_README = os.path.join(ROOT, "infra", "k8s", "README.md")
SERVICE = "backend"

# 값이 아직 어디에도 없어 주입할 수 없는 이름. 주입 누락과 구분하기 위해 명시한다.
# 값이 정해져 주입되면 이 목록에서 지운다 — 지우지 않으면 아래 '목록이 낡았다' 로 실패한다.
PENDING = {
    # 예시)
    #   "SOME_KEY": "외부 발급 대기. 값이 정해지면 이 줄을 지운다 (FINCH-xxx)",
}

MIN_REQUIRED = 5
MIN_INJECTED = 5

PLACEHOLDER = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)(:([^}]*))?\}")
ENV_NAME = re.compile(r"^\s*- name: ([A-Z_][A-Z0-9_]*)", re.M)
SECRET_REF = re.compile(r"secretRef:\s*\n\s*name: ([a-z0-9-]+)")
FROM_LITERAL = re.compile(r"--from-literal=([A-Z_][A-Z0-9_]*)")


def die(msg):
    sys.stderr.write("✗ %s\n" % msg)
    sys.exit(1)


def read(path):
    if not os.path.isfile(path):
        die("파일이 없습니다: %s" % path)
    return io.open(path, encoding="utf-8").read()


def required_names(text):
    found = {}
    for m in PLACEHOLDER.finditer(text):
        found.setdefault(m.group(1), m.group(3))
    return found


def compose_injected(text, service):
    block = re.search(r"^  %s:\n(.*?)(?=^  \S|\Z)" % re.escape(service), text, re.S | re.M)
    if not block:
        die("compose 에서 '%s' 서비스를 찾지 못했습니다. 파서를 고쳐야 합니다." % service)
    env = re.search(r"^    environment:\n(.*?)(?=^    \S|\Z)", block.group(1), re.S | re.M)
    if not env:
        die("'%s' 서비스에 environment: 블록이 없습니다." % service)
    return set(re.findall(r"^      ([A-Z_][A-Z0-9_]*):", env.group(1), re.M))


def chart_injected(chart_text, readme_text):
    """차트가 backend 컨테이너에 주는 키.

    inline env 와, secretRef 가 담는 키를 합친다. Secret 의 내용은 클러스터에만
    있으므로 README 의 create secret 명령에 적힌 --from-literal 을 계약으로 본다.
    """
    inline = set(ENV_NAME.findall(chart_text))
    refs = SECRET_REF.findall(chart_text)
    from_secret = set()
    for name in refs:
        m = re.search(
            r"create secret generic %s\b(.*?)(?=\n[a-z#]|\n\n|\Z)" % re.escape(name),
            readme_text, re.S)
        if m:
            from_secret |= set(FROM_LITERAL.findall(m.group(1)))
    return inline | from_secret, refs


def report_missing(label, missing, required, how):
    sys.stderr.write("\n✗ %s %d개\n\n" % (label, len(missing)))
    for name in missing:
        default = required[name]
        if default is None:
            sys.stderr.write(
                "  %s (기본값 없음)\n"
                "    @ConfigurationProperties 바인딩은 해석 안 되는 placeholder 를 예외 대신\n"
                "    문자열로 남긴다. 기동은 성공하고 그 값을 쓰는 시점에 실패한다.\n" % name)
        else:
            sys.stderr.write(
                "  %s (기본값 '%s')\n"
                "    그 기본값으로 조용히 뜬다. 로그에 아무 신호가 없다.\n" % (name, default))
    sys.stderr.write(how)


def main():
    required = required_names(read(APP_YAML))
    compose_keys = compose_injected(read(COMPOSE), SERVICE)

    if len(required) < MIN_REQUIRED or len(compose_keys) < MIN_INJECTED:
        die("파싱 결과가 비정상입니다 (요구 %d개, compose 주입 %d개).\n"
            "  파일 구조가 바뀌었을 수 있습니다. 조용히 통과하지 않도록 실패로 처리합니다."
            % (len(required), len(compose_keys)))

    chart_keys, refs = chart_injected(read(CHART), read(CHART_README))

    print("요구 %d개 / compose 주입 %d개 / 차트 주입 %d개 / 값 미정 %d개"
          % (len(required), len(compose_keys), len(chart_keys), len(PENDING)))
    print("차트 secretRef: %s" % (", ".join(refs) or "없음"))

    ok = True

    compose_missing = sorted(
        n for n in required if n not in compose_keys and n not in PENDING)
    if compose_missing:
        ok = False
        report_missing(
            "compose 가 주지 않는 환경변수", compose_missing, required,
            "\n  고치는 방법 — infra/docker-compose.yml 의 %s 서비스 environment: 에 추가한다.\n"
            "    비밀값이면      NAME: ${NAME:?NAME 가 필요합니다}   + Jenkins Credentials 등록\n"
            "    비밀값이 아니면 NAME: ${NAME:-운영기본값}\n"
            "  값이 아직 없어 주입할 수 없다면 이 스크립트의 PENDING 에 이유와 함께 넣는다.\n"
            % SERVICE)

    chart_missing = sorted(
        n for n in required if n not in chart_keys and n not in PENDING)
    if chart_missing:
        ok = False
        report_missing(
            "Helm 차트가 주지 않는 환경변수", chart_missing, required,
            "\n  고치는 방법\n"
            "    비밀값이면      infra/k8s/README.md 의 create secret 명령에 --from-literal 을 더하고\n"
            "                    차트에 그 Secret 을 envFrom: secretRef 로 연결한다\n"
            "    비밀값이 아니면 templates/backend.yaml 의 env: 에 추가하고 값은 values.yaml 에 둔다\n"
            "                    (git 에 남아 코드 리뷰를 받는다)\n")

    stale = sorted(n for n in PENDING if n in compose_keys or n in chart_keys)
    if stale:
        ok = False
        sys.stderr.write("\n✗ PENDING 목록이 낡았습니다 — 이미 주입된 이름이 남아 있습니다\n")
        for name in stale:
            sys.stderr.write("  %s → PENDING 에서 지우세요\n" % name)

    unknown = sorted(n for n in PENDING if n not in required)
    if unknown:
        ok = False
        sys.stderr.write("\n✗ PENDING 에 application.yaml 이 요구하지 않는 이름이 있습니다\n")
        for name in unknown:
            sys.stderr.write("  %s → 계약에서 사라졌다면 PENDING 에서도 지우세요\n" % name)

    if not ok:
        return 1

    if PENDING:
        print("\n값 미정 (주입 누락이 아니다)")
        for name in sorted(PENDING):
            print("  %s — %s" % (name, PENDING[name]))

    print("\n✓ 계약 일치 — compose 와 차트 양쪽이 요구되는 이름을 모두 준다")
    return 0


if __name__ == "__main__":
    sys.exit(main())
