FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*

ARG ANSIBLE_VERSION=10.7.0
RUN pip install --no-cache-dir "ansible==${ANSIBLE_VERSION}"

WORKDIR /ansible
ENTRYPOINT ["ansible-playbook"]
