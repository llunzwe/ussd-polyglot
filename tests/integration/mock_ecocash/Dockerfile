FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir flask

COPY tests/integration/mock_ecocash/app.py ./

ENV PORT=8080
ENV FLASK_APP=app.py

EXPOSE 8080

CMD ["python", "-m", "flask", "run", "--host=0.0.0.0", "--port=8080"]
