FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py device_links.py sync_preferences.py library_sync.py integration_bidirectional.py ./

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

EXPOSE 8787

CMD ["gunicorn", "--bind", "0.0.0.0:8787", "--workers", "1", "--threads", "4", "--timeout", "0", "app:app"]
