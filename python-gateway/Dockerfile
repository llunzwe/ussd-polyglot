# syntax=docker/dockerfile:1

FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY python-gateway/requirements.txt ./
RUN grep -v 'llama-cpp-python' requirements.txt > requirements-core.txt && \
    pip install --timeout 300 --retries 5 --no-cache-dir -r requirements-core.txt && \
    rm requirements-core.txt

# Copy source code
COPY python-gateway/run.py ./
COPY python-gateway/src/ ./src/

ENV PYTHONPATH=/app/src
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["python", "run.py"]
