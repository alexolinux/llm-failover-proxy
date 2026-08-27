FROM python:3.12-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=4000 \
    HOST=0.0.0.0

# Install runtime dependencies (curl for healthcheck)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY . .

# Expose default proxy port
EXPOSE 4000

# Healthcheck to verify proxy liveliness
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://127.0.0.1:${PORT}/health/liveliness || exit 1

# Start LiteLLM proxy
CMD ["sh", "-c", "exec env -u DEBUG litellm --config /app/config.yaml --port ${PORT} --host ${HOST}"]
