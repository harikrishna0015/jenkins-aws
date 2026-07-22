# Jenkins inbound (JNLP) agent customized for the Healthcare Claims pipeline.
#
# Base image is the official inbound agent. It already ships the JNLP
# connection logic and a JDK. We add the build tools our pipeline needs:
# the AWS CLI v2 (cloudformation/s3/ecr), zip (Lambda packaging), jq, git.
#
# The inbound entrypoint is preserved so Jenkins ECS plugin can pass the
# controller URL, agent secret, and workDir as arguments.

FROM jenkins/inbound-agent:latest

USER root

# Install OS-level build tools, then AWS CLI v2.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        unzip \
        zip \
        jq \
        git \
        ca-certificates \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && rm -rf /var/lib/apt/lists/*

# Smoke-check the toolchain at build time so a broken image fails early.
RUN aws --version && jq --version && git --version && zip --version

# Drop back to the non-root jenkins user; the inbound entrypoint runs as it.
USER jenkins
