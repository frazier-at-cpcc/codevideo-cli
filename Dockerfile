# codevideo-cli render worker image (multi-stage).
#
# Build stage compiles the Go CLI with the exact toolchain go.mod pins (1.26) —
# don't rely on the runtime image's packaged Go, which lags. Runtime stage is
# zenika/alpine-chrome:with-puppeteer (Chromium + Node + Puppeteer) plus ffmpeg
# (the webm -> mp4 step shells out to it). Published to Docker Hub as
# fullstackcraft/codevideo-cli and pulled by the codevideo-api compose stack.

# ---- build: compile the static Go binary --------------------------------------
FROM golang:1.26-alpine AS build
RUN apk add --no-cache git
WORKDIR /src

# Go deps first for layer caching.
COPY go.mod go.sum ./
RUN go mod download

# CGO off -> a fully static binary that runs on the Alpine runtime base. VERSION
# is injected by release builds (consumed by main.go's `var version`).
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" -o /out/codevideo

# ---- runtime: Google Chrome + Node + ffmpeg ------------------------------------
# puppeteer-stream >= 3 loads its recorder extension through the devtools
# `Extensions.loadUnpacked` command, which needs a current Chrome. The
# zenika/alpine-chrome:with-puppeteer image stopped at Chromium 124, where that
# command does not exist and every render fails with
# "Protocol error (Extensions.loadUnpacked): 'Extensions.loadUnpacked' wasn't found".
# Debian + google-chrome-stable tracks current Chrome. amd64 only (Google does
# not publish an arm64 .deb); for arm64 substitute Debian's `chromium` package.
FROM node:20-bookworm-slim AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends wget gnupg ca-certificates ffmpeg \
       fonts-liberation fonts-noto-color-emoji fonts-dejavu-core \
  && wget -qO- https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
  && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends google-chrome-stable \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The compiled worker. The Gatsby static site is go:embed'd into the binary, so
# nothing else is needed for the manifest/static servers.
COPY --from=build /out/codevideo /app/codevideo

# The Puppeteer runner + its Node deps. server.go execs
# `node <execDir>/puppeteer-runner/recordVideoV3.js`, so it must sit next to the
# binary. Chromium comes from the base image — no browser download here.
COPY puppeteer-runner/ /app/puppeteer-runner/
WORKDIR /app/puppeteer-runner
RUN npm install
WORKDIR /app

# Runtime config for the containerized serve worker:
#   CODEVIDEO_CHROME_PATH - resolveChromeExecutable() honors this first, so pin
#     the base image's Chromium instead of relying on PATH resolution.
#   CODEVIDEO_WORK_DIR    - the shared render queue the API bind-mounts in. Go's
#     WorkFolder()/VideoFolder() and the --manifest-path/--output-webm args
#     passed to the Node runner all derive from it, keeping both sides in sync.
ENV CODEVIDEO_CHROME_PATH=/usr/bin/google-chrome-stable \
    CODEVIDEO_WORK_DIR=/work/tmp/v3

# Filesystem-queue worker: no inbound port. The manifest (:7000) and static
# (:7001) servers it starts are reached only by its own Puppeteer over
# localhost, so nothing is published.
ENTRYPOINT ["/app/codevideo"]
CMD ["-m", "serve"]
