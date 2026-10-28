FROM python:3.12-alpine

# curl is used by `kubectl exec <inventory-pod> -- curl ...` to toggle readiness on one Pod.
RUN apk add --no-cache curl

WORKDIR /app
COPY server.py .

# Run as an unprivileged user.
RUN adduser -D -u 10001 inventory
USER 10001

ENV PORT=8080 \
    PYTHONUNBUFFERED=1
EXPOSE 8080

CMD ["python", "/app/server.py"]
