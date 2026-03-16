FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# PyTorch CPU (for Silero VAD)
RUN pip install --no-cache-dir \
    torch torchaudio --index-url https://download.pytorch.org/whl/cpu

# App deps (from default PyPI)
RUN pip install --no-cache-dir \
    fastapi "uvicorn[standard]" websockets \
    openwakeword onnxruntime numpy

COPY app/ /app/app/

WORKDIR /app
EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
