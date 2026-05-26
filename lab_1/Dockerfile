# syntax=docker/dockerfile:1
# Use AWS's public ECR mirror of Docker Hub instead of pulling docker.io
# directly. Docker Hub anonymous pulls are rate-limited to 100 per 6h per
# source IP, and CodeBuild fleet IPs are shared -- so a class of students
# all building at once will trip the limit and the build will 429.
# public.ecr.aws/docker/library/ is the same image, hosted on AWS, no
# rate limit, no auth needed.
FROM public.ecr.aws/docker/library/python:3.12-slim

# Don't write .pyc files, flush logs immediately
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install Python dependencies first so this layer caches between builds.
COPY src/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copy the application source.
COPY src/ /app/

# Drop to a non-root user. EKS pod security baseline expects this.
RUN groupadd --gid 10001 app && \
    useradd  --uid 10001 --gid app --shell /usr/sbin/nologin --no-create-home app && \
    chown -R app:app /app
USER 10001

EXPOSE 8080

# gunicorn serves the Flask app defined in src/app.py (module `app`, callable `app`).
# 2 workers is appropriate for the tiny lab pod resource requests.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "app:app"]
