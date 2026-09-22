IMAGE    ?= intra-toolbox
ENV_DIR  ?= tofu/environments/intra
PLAYBOOK ?= playbooks/update.yaml
EXTRA    ?=

# Credentials come from env: PROXMOX_VE_*, PG_CONN_STR, TF_ENCRYPTION, ANSIBLE_VAULT_PASSWORD_FILE, SSH_AUTH_SOCK.
DOCKER = docker run --rm -it \
	-u "$$(id -u):$$(id -g)" \
	-v "$(CURDIR):/work" \
	$(if $(SSH_AUTH_SOCK),-v "$(SSH_AUTH_SOCK):/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent,) \
	-e PROXMOX_VE_HOST -e PROXMOX_VE_USER \
	-e PROXMOX_VE_TOKEN_ID -e PROXMOX_VE_TOKEN_SECRET \
	-e PROXMOX_VE_ENDPOINT -e PROXMOX_VE_API_TOKEN -e PROXMOX_VE_INSECURE \
	-e PG_CONN_STR -e TF_ENCRYPTION \
	-e ANSIBLE_VAULT_PASSWORD_FILE \
	-e FLEET_SUBNET_RE \
	$(IMAGE)

TOFU    = $(DOCKER) tofu -chdir=$(ENV_DIR)
ANSIBLE = $(DOCKER) bash -c 'cd ansible && exec "$$@"' --

.PHONY: image iso guard init plan apply destroy fmt validate configure controller vault inventory shell lint

image:
	docker build -t $(IMAGE) .

# No -it here, so it also runs from scripts without a terminal.
iso:
	@[ -n "$(BASE)" ] || { echo 'usage: make iso BASE=<debian-netinst.iso> [EXTRA=--fetch-keys]'; exit 1; }
	@base=$$(eval printf '%s' "$(BASE)"); \
	[ -f "$$base" ] || { echo "no such file: $$base"; exit 1; }; \
	docker run --rm -u "$$(id -u):$$(id -g)" \
		-v "$(CURDIR):/work" \
		-v "$$(cd -- "$$(dirname -- "$$base")" && pwd):/base:ro" \
		$(IMAGE) images/debian/build-image.sh build \
			--base "/base/$$(basename -- "$$base")" $(EXTRA)

# apply refuses a dirty or out-of-date checkout; plan does not.
guard:
	@git diff --quiet || { echo "working tree is dirty - commit first"; exit 1; }
	@git rev-parse @{u} >/dev/null 2>&1 || { echo "no upstream branch, skipping the freshness check"; exit 0; }
	@git fetch -q origin && git diff --quiet @ @{u} || { echo "behind origin - pull first"; exit 1; }

init:
	$(TOFU) init

plan:
	$(TOFU) plan

apply: guard
	$(TOFU) apply

destroy:
	$(TOFU) destroy

fmt:
	$(DOCKER) tofu fmt -recursive tofu

validate:
	$(TOFU) validate

configure:
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) $(EXTRA)

# Bootstrap: ctrl is targeted by name because it has no inventory tag yet.
controller:
	$(ANSIBLE) ansible-playbook playbooks/controller.yaml -e controller_hosts=ctrl $(EXTRA)

vault:
	$(ANSIBLE) ansible-vault create inventory/group_vars/tag_controller.yml

inventory:
	$(ANSIBLE) ansible-inventory --graph

lint:
	$(ANSIBLE) ansible-playbook --syntax-check playbooks/*.yaml

shell:
	$(DOCKER) bash
