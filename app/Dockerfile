# Build from the REPO ROOT (the image needs data/service_priority.xlsx):
#   docker build --platform linux/amd64 -f app/Dockerfile -t finops-cloudscale-app .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    WEB_CONCURRENCY=2 \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus \
    PRIORITY_FILE=/srv/data/service_priority.xlsx

WORKDIR /srv

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/cloudscale ./cloudscale
COPY data/service_priority.xlsx ./data/service_priority.xlsx

RUN useradd --uid 10001 --no-create-home app
USER app

EXPOSE 8080

# Several uvicorn processes so a 2-vCPU t3 can reach the 50% CPU scaling target.
# Access logs are off: every request line would be billed as CloudWatch Logs ingestion.
CMD ["sh", "-c", "rm -rf \"$PROMETHEUS_MULTIPROC_DIR\" && mkdir -p \"$PROMETHEUS_MULTIPROC_DIR\" && exec uvicorn cloudscale.main:app --host 0.0.0.0 --port \"$PORT\" --workers \"$WEB_CONCURRENCY\" --timeout-graceful-shutdown 60 --no-access-log"]
