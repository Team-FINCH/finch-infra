# ai 파트 (FastAPI) — 기동 시 alembic 마이그레이션 적용 후 uvicorn 실행
FROM python:3.12-slim
WORKDIR /app

COPY ai/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY ai/ ./

EXPOSE 8000
# nginx 가 /ai 프리픽스를 벗겨서 넘겨주므로 앱은 / 기준으로 동작한다.
# /docs 링크가 어긋나면 --root-path /ai 옵션을 추가할 것 (infra/nginx/nginx.conf 주석 참고).
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.api.main:app --host 0.0.0.0 --port 8000"]
