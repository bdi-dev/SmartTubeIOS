FROM python:3.12-slim
# ffmpeg merges separate video+audio; deno is the JavaScript runtime yt-dlp uses for YouTube.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno
# Unpinned on purpose: YouTube changes often. Rebuild (or `pip install -U yt-dlp` in the container) to update.
RUN pip install --no-cache-dir -U yt-dlp
WORKDIR /app
COPY server.py .
ENV YTDLP_HOST=0.0.0.0 YTDLP_PORT=8787 YTDLP_DATA_DIR=/data
VOLUME /data
EXPOSE 8787
CMD ["python", "server.py"]
