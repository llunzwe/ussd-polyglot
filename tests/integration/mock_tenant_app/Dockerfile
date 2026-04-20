FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir grpcio protobuf

COPY python-gateway/src/openai_ussd_kernel/protos/ ./protos/
COPY tests/integration/mock_tenant_app/app.py ./

ENV PYTHONPATH=/app
ENV PORT=50053

EXPOSE 50053

CMD ["python", "app.py"]
