FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN useradd --system --uid 10001 --no-create-home app
WORKDIR /srv
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY anden_api ./anden_api
USER app
EXPOSE 8520
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8520/health', timeout=4)"
CMD ["python", "-m", "anden_api.server"]
