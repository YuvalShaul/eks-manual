FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ARG VERSION=dev
ENV VERSION=$VERSION
EXPOSE 5000
CMD ["python", "app.py"]
