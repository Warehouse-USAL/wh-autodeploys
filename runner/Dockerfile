# Self-hosted GitHub Actions runner that can drive the host Docker daemon.
# Base image self-registers from ACCESS_TOKEN (a PAT) and runs as a service.
# We add the tools the deploy jobs need: docker compose plugin, make, git.
FROM myoung34/github-runner:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends make git curl ca-certificates jq \
 && mkdir -p /usr/libexec/docker/cli-plugins \
 && curl -fsSL \
      "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
      -o /usr/libexec/docker/cli-plugins/docker-compose \
 && chmod +x /usr/libexec/docker/cli-plugins/docker-compose \
 && rm -rf /var/lib/apt/lists/* \
 && docker compose version
