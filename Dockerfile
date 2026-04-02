FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    x11vnc \
    novnc \
    websockify \
    wget \
    ca-certificates \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xdg-utils \
    redsocks \
    iptables \
    gosu \
    # Base font packages
    fonts-liberation \
    fonts-dejavu-core \
    fonts-freefont-ttf \
    fonts-noto-core \
    fonts-noto-mono \
    fonts-urw-base35 \
    fontconfig \
    && rm -rf /var/lib/apt/lists/*

# Install Microsoft core fonts (Arial, Times New Roman, Verdana, Georgia, etc.)
# ttf-mscorefonts-installer lives in contrib; enable it first
RUN echo "deb http://deb.debian.org/debian trixie main contrib" > /etc/apt/sources.list.d/contrib.list \
    && echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
        | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ttf-mscorefonts-installer \
        # Metric-compatible replacements for proprietary MS Office fonts:
        # fonts-crosextra-carlito  ≈ Calibri  (default Office 2007+ body font)
        # fonts-crosextra-caladea ≈ Cambria   (default Office 2007+ heading font)
        fonts-crosextra-carlito \
        fonts-crosextra-caladea \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

RUN pip install --no-cache-dir "camoufox[geoip]==0.4.11"

RUN useradd -m -s /bin/bash user

RUN camoufox fetch \
    && mkdir -p /home/user/.cache \
    && cp -r /root/.cache/camoufox /home/user/.cache/camoufox \
    && chown -R user:user /home/user/.cache/camoufox

COPY scripts/ /scripts/
RUN chmod +x /scripts/start.sh /scripts/setup-proxy.sh /scripts/check-fingerprint.py /scripts/warmup.py

EXPOSE 6901

# Entrypoint runs as root to configure iptables, then drops to user
ENTRYPOINT ["/scripts/start.sh"]