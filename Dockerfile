FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin leadfinder

WORKDIR /app
COPY --chown=leadfinder:leadfinder . .
RUN chmod +x lead_finder.sh src/*.sh && mkdir -p leads && chown leadfinder:leadfinder leads

USER leadfinder
ENV HOST=0.0.0.0 PORT=8080 PYTHONUNBUFFERED=1
EXPOSE 8080
VOLUME ["/app/leads"]

HEALTHCHECK --interval=30s --timeout=5s CMD curl -s -o /dev/null http://127.0.0.1:8080/ || exit 1

CMD ["python3", "server.py"]
