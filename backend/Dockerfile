# Backend image: Flask API served by gunicorn.
# No passwords or keys in this file. Settings arrive as environment variables at run time.
FROM python:3.12-slim

# The image tag is passed in at build time so the running app can report its own version.
ARG APP_VERSION=unknown
ENV APP_VERSION=${APP_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a normal user, not root.
RUN useradd --create-home appuser
USER appuser

EXPOSE 5000

# --preload loads the app once before the workers start, so the table is created only once.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--preload", "app:app"]
