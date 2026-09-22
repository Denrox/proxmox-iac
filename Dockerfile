FROM debian:trixie-slim

ARG TOFU_VERSION=1.12.6
ARG TOFU_SHA256=5dc43da4f750f33873dc25e94587128709e819e544b7be9016b255316153c3a8
ARG ANSIBLE_CORE_VERSION=2.21.3

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		git \
		make \
		openssh-client \
		python3 \
		python3-venv \
		rsync \
		unzip \
		whois \
		xorriso \
	&& rm -rf /var/lib/apt/lists/*
# xorriso and whois (mkpasswd) are for images/debian.

RUN curl -fsSLo /tmp/tofu.zip \
		"https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
	&& echo "${TOFU_SHA256}  /tmp/tofu.zip" | sha256sum -c - \
	&& unzip -j /tmp/tofu.zip tofu -d /usr/local/bin \
	&& rm /tmp/tofu.zip

# Trixie enforces PEP 668, so Ansible gets a venv.
RUN python3 -m venv /opt/ansible \
	&& /opt/ansible/bin/pip install --no-cache-dir \
		"ansible-core==${ANSIBLE_CORE_VERSION}" \
		proxmoxer \
		requests
ENV PATH="/opt/ansible/bin:${PATH}"

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml \
		-p /usr/share/ansible/collections \
	&& rm /tmp/requirements.yml
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections

# The caller's uid has no home; HOME on the bind mount also keeps the provider cache.
ENV HOME=/work
WORKDIR /work

# entrypoint.sh adds the caller's uid to /etc/passwd.
RUN chmod 0666 /etc/passwd
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["bash"]
