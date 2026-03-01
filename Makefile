.PHONY: help init init-keys plan apply destroy destroy-quick validate fmt clean check-prereqs check-rancher-tools install-kubectl-tools replace-node

# Terraform directory
TF_DIR := terraform

help:
	@echo "Rancher on Proxmox - Terraform Management"
	@echo "=========================================="
	@echo ""
	@echo "Available targets:"
	@echo "  check-prereqs        - Check for required tools (terraform, curl, ssh, jq)"
	@echo "  init-keys            - Create .keys/ and SSH key for access/management (do not use host ~/.ssh)"
	@echo "  check-rancher-tools  - Check for Rancher deployment tools (helm, kubectl)"
	@echo "  install-kubectl-tools - Install optional kubectx and kubens plugins"
	@echo ""
	@echo "Terraform Operations:"
	@echo "  init                 - Initialize Terraform"
	@echo "  plan                 - Show infrastructure plan"
	@echo "  apply                - Deploy infrastructure with logging"
	@echo "  destroy              - Destroy infrastructure (interactive)"
	@echo "  destroy-quick        - Destroy without confirmation"
	@echo "  validate             - Validate Terraform configuration"
	@echo "  fmt                  - Format Terraform files"
	@echo "  clean                - Remove Terraform cache and state"
	@echo "  replace-node         - Replace one VM (drain, replace, sync). Use: make replace-node CLUSTER=manager NODE=rancher-manager-2"
	@echo "  help                 - Show this help message"
	@echo ""
	@echo "Usage:"
	@echo "  1. make check-prereqs    - Verify tools are installed"
	@echo "  2. make init-keys        - Create .keys/ and SSH key (then add .keys/rancher-api-token)"
	@echo "  3. make init             - Initialize Terraform"
	@echo "  4. make plan             - Preview changes"
	@echo "  5. make apply            - Deploy infrastructure"

check-prereqs:
	@echo "Checking prerequisites..."
	@echo ""
	@MISSING_TOOLS=0; \
	TOOLS="terraform curl ssh jq"; \
	for tool in $$TOOLS; do \
	  if ! command -v $$tool >/dev/null 2>&1; then \
	    echo "✗ $$tool is required but not installed"; \
	    MISSING_TOOLS=1; \
	  else \
	    echo "✓ $$tool found"; \
	  fi; \
	done; \
	if [ $$MISSING_TOOLS -eq 1 ]; then \
	  echo ""; \
	  echo "Installation instructions:"; \
	  echo "  Ubuntu/Debian:"; \
	  echo "    sudo apt-get update && sudo apt-get install -y curl openssh-client jq"; \
	  echo "    wget https://apt.releases.hashicorp.com/gpg | sudo apt-key add -"; \
	  echo "    sudo apt-get install -y terraform"; \
	  echo "  macOS (with Homebrew):"; \
	  echo "    brew install terraform curl openssh jq"; \
	  echo "  Or download directly:"; \
	  echo "    Terraform: https://www.terraform.io/downloads"; \
	  exit 1; \
	fi; \
	echo ""; \
	echo "✓ All required tools found"

init-keys:
	@./scripts/setup-keys.sh

# Replace one node VM (inaccessible node). Cluster: manager | nprd-apps | prd-apps | poc-apps. Node: e.g. rancher-manager-2, nprd-apps-worker-1
replace-node:
	@if [ -z "$(CLUSTER)" ] || [ -z "$(NODE)" ]; then \
	  echo "Usage: make replace-node CLUSTER=<manager|nprd-apps|prd-apps|poc-apps> NODE=<node-name>"; \
	  echo "Example: make replace-node CLUSTER=manager NODE=rancher-manager-2"; \
	  exit 1; \
	fi; \
	./scripts/replace-node.sh "$(CLUSTER)" "$(NODE)"

check-rancher-tools:
	@echo "Checking Rancher deployment tools..."
	@echo ""
	@MISSING_TOOLS=0; \
	TOOLS="helm kubectl"; \
	for tool in $$TOOLS; do \
	  if ! command -v $$tool >/dev/null 2>&1; then \
	    echo "✗ $$tool is required for Rancher deployment but not installed"; \
	    MISSING_TOOLS=1; \
	  else \
	    echo "✓ $$tool found"; \
	  fi; \
	done; \
	if [ $$MISSING_TOOLS -eq 1 ]; then \
	  echo ""; \
	  echo "Installation instructions:"; \
	  echo "  helm (Kubernetes package manager):"; \
	  echo "    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"; \
	  echo "    Or: brew install helm (macOS)"; \
	  echo ""; \
	  echo "  kubectl (Kubernetes CLI):"; \
	  echo "    curl -LO \"https://dl.k8s.io/release/\$$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""; \
	  echo "    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"; \
	  echo "    Or: brew install kubectl (macOS)"; \
	  exit 1; \
	fi; \
	echo ""; \
	echo "✓ All Rancher tools found"; \
	echo ""; \
	echo "Optional tools for improved kubectl experience:"; \
	echo "  • kubectx (switch between clusters): https://github.com/ahmetb/kubectx"; \
	echo "  • kubens (switch between namespaces): https://github.com/ahmetb/kubectx/tree/master/kubens"; \
	if command -v kubectx >/dev/null 2>&1; then echo "    ✓ kubectx installed"; else echo "    Install: sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx && sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx"; fi; \
	if command -v kubens >/dev/null 2>&1; then echo "    ✓ kubens installed"; else echo "    Install: sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens"; fi

# Terraform targets
init: check-prereqs
	@cd $(TF_DIR) && terraform init

plan: init
	@cd $(TF_DIR) && terraform plan -out=tfplan

apply:
	@./scripts/apply.sh

destroy:
	@./scripts/destroy.sh

destroy-quick:
	@echo "⚠️  Quick destroy without confirmation (use with caution!)"
	@cd $(TF_DIR) && terraform destroy -auto-approve -parallelism=3
	@rm -fv $(TF_DIR)/.manager-token 2>/dev/null || true
	@rm -fv ~/.kube/rancher-manager.yaml 2>/dev/null || true
	@echo "✓ Infrastructure destroyed"

validate:
	@cd $(TF_DIR) && terraform validate

fmt:
	@cd $(TF_DIR) && terraform fmt -recursive

clean:
	@cd $(TF_DIR) && rm -rf .terraform .terraform.lock.hcl tfplan terraform.tfstate*
	@echo "✓ Cleaned"

install-kubectl-tools:
	@echo "Installing optional kubectl plugins (kubectx and kubens)..."
	@echo ""
	@if [ -d "/opt/kubectx" ]; then \
	  echo "kubectx already installed at /opt/kubectx"; \
	else \
	  echo "Cloning kubectx repository..."; \
	  sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx; \
	fi
	@echo ""
	@echo "Setting up kubectx command..."
	@sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
	@echo "✓ kubectx installed"
	@echo ""
	@echo "Setting up kubens command..."
	@sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
	@echo "✓ kubens installed"
	@echo ""
	@echo "Usage:"
	@echo "  kubectx               - List/switch clusters (like 'cd' for clusters)"
	@echo "  kubectx <cluster>     - Switch to a cluster"
	@echo "  kubens                - List/switch namespaces"
	@echo "  kubens <namespace>    - Switch to a namespace"
	@echo ""
	@echo "Examples:"
	@echo "  kubectx rancher-manager   - Switch to manager cluster"
	@echo "  kubens kube-system        - Switch to kube-system namespace"
	@echo "  kubectx -                 - Switch back to previous cluster"
	@echo ""
	@echo "✓ Installation complete!"

