FROM python:3.12-slim

# Build-time metadata baked into the image so every tag is visibly different.
# Override with: docker build --build-arg APP_VERSION=1.1.0 ...
ARG APP_VERSION=dev
ARG APP_RELEASE_NOTE="Local development build"
ENV APP_VERSION=${APP_VERSION} \
    APP_RELEASE_NOTE=${APP_RELEASE_NOTE} \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY multidimensional-portal-generator/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY multidimensional-portal-generator/src ./src

EXPOSE 8000
# exec: uvicorn replaces sh as PID 1, so it receives SIGTERM from Kubernetes
# and shuts down gracefully instead of being SIGKILLed after the grace period.
CMD ["sh", "-c", "exec uvicorn src.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
