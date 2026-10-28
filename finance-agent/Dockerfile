# Base image pinned by digest; Dependabot proposes updates as reviewed pull requests.
FROM python:3.11.18-slim-bookworm@sha256:90d117a7f1ef6535dc75831e1a9184725757fede0d4d424d7977fb5429d50610

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# requirements.txt is a hash-locked file generated from requirements.in.
COPY requirements.txt .
# Packaging tools are not needed at runtime; removing them drops their CVEs from the image.
RUN pip install --require-hashes -r requirements.txt \
 && pip uninstall -y setuptools wheel

# The .env file is excluded by .dockerignore; Compose supplies it at runtime.
COPY agent.py auth.py main.py tools.py ./

# Unprivileged numeric UID so Kubernetes runAsNonRoot can verify it.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

EXPOSE 9001

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9001/health', timeout=2)"]

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9001", "--no-server-header"]
