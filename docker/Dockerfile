FROM python:3.11-slim
WORKDIR /app
RUN pip install flask pyyaml
COPY app/ /app/
CMD ["python", "app.py"]
