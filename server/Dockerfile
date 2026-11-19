# Must match .python-version / requires-python. uv refuses to use an
# interpreter older than the project requires, and would silently download its
# own instead of using this one.
FROM python:3.14-slim

# Install system dependencies (FFmpeg)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Deno natively
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh

# Install uv by copying it directly from the official Astral image
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Set working directory
WORKDIR /app

# Enable bytecode compilation and copy files
ENV UV_COMPILE_BYTECODE=1
ENV VIRTUAL_ENV=/app/.venv
# Use the interpreter in this image and never fetch another. requires-python is
# an open-ended ">=3.14", so left to itself uv picks the newest CPython that
# exists at build time — which is how this build broke the day 3.15 shipped:
# uv.lock pins psycopg-binary, which publishes cp314 wheels and no sdist, so a
# 3.15 interpreter has nothing to install. Failing loudly beats drifting.
ENV UV_PYTHON_DOWNLOADS=never
# .python-version is copied too, so uv pins the same version here as it does
# locally rather than inferring one.
COPY pyproject.toml uv.lock .python-version ./

# Install dependencies (without installing the root package yet)
RUN uv sync --frozen --no-install-project --no-dev

# Copy the rest of the application source code
COPY . .

# Build/sync the project root
RUN uv sync --frozen --no-dev

# Place virtualenv executables at the front of PATH
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH=/app/src

# Expose port 8000
EXPOSE 8000

# Run uvicorn directly (no need to specify full path to .venv/bin)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]