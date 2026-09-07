# ai 파트 (FastAPI) — 기동 시 alembic 마이그레이션 적용 후 uvicorn 실행
FROM python:3.12-slim
WORKDIR /app

COPY ai/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY ai/ ./

EXPOSE 8000
# 백엔드가 컨테이너 네트워크에서 http://ai:8000 으로 직접 호출하므로 앱은 / 기준으로 동작한다.
# (외부 노출 없음 — infra/nginx/nginx.conf 주석 참고)
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.api.main:app --host 0.0.0.0 --port 8000"]
