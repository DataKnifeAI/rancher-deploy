# Contributing to Rancher Deploy

Thank you for your interest in contributing! We welcome contributions from the community.

## Code of Conduct

Please review our [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/your-username/rancher-deploy.git
   cd rancher-deploy
   ```

3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Setup

### Prerequisites
- Terraform >= 1.5
- Proxmox VE 8.0+ with API token
- SSH key for VM access
- Git for version control

### Build and Test

```bash
# Initialize Terraform
cd terraform
terraform init

# Validate configuration
terraform validate

# Format code
terraform fmt -recursive

# Plan deployment (test mode)
terraform plan -out=tfplan

# Destroy test infrastructure
terraform destroy -auto-approve
```

## Making Changes

### Code Standards

- **Terraform**: Follow HashiCorp conventions
  - Use snake_case for variables and outputs
  - Document all variables with descriptions
  - Mark sensitive values with `sensitive = true`
  - Run `terraform fmt -recursive` before commit

- **Shell Scripts**: Follow POSIX conventions
  - Use consistent indentation (2 spaces)
  - Add comments for complex logic
  - Test on multiple shell interpreters

- **Documentation**: Use Markdown
  - Clear, concise language
  - Code examples for all features
  - Cross-references to related topics

### Testing Changes

1. **Syntax validation**:
   ```bash
   cd terraform
   terraform validate
   terraform fmt -recursive
   ```

2. **Plan validation** (in test environment):
   ```bash
   terraform plan -out=tfplan
   # Review plan carefully
   ```

3. **Full integration test** (in staging):
   ```bash
   terraform apply tfplan
   # Verify all resources created correctly
   terraform destroy -auto-approve
   ```

### Documentation Updates

- Update relevant docs in `docs/` folder
- If modifying Terraform variables, update [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example) and the variable descriptions in `terraform/variables.tf`
- If fixing an issue, add to [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Update [CHANGELOG.md](CHANGELOG.md) with your changes

## Submitting Changes

1. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

2. **Open a Pull Request** with:
   - Clear description of changes
   - Reference to any related issues (#123)
   - Explanation of why the change is needed
   - Testing performed

3. **Wait for review** - maintainers will review and provide feedback

### Pull Request Template

```markdown
## Description
Brief description of what this PR does.

## Motivation
Why is this change needed?

## Testing
How was this tested?

## Checklist
- [ ] Terraform code validated (`terraform validate`)
- [ ] Code formatted (`terraform fmt -recursive`)
- [ ] Documentation updated
- [ ] Changes tested in staging environment
- [ ] No secrets or sensitive data in code
```

## Reporting Issues

### Bugs
- Use the bug report template
- Include reproduction steps
- Provide Terraform plan output
- Include error logs (with `TF_LOG=debug`)

### Feature Requests
- Explain the use case
- Describe the desired behavior
- Provide examples

### Security Issues
- **Do NOT open public issues**
- Email the maintainers directly
- Include detailed description and reproduction steps
- Allow time for fix before public disclosure

## Version Management

### RKE2 Versions

**CRITICAL**: Always use specific released versions, NOT "latest"

- Check available versions: https://github.com/rancher/rke2/tags
- Examples: `v1.34.3+rke2r1`, `v1.33.7+rke2r1`
- Update in:
  - `terraform/main.tf` (both cluster definitions)
  - `terraform/modules/rke2_cluster/main.tf` (module default)
  - Document in [CHANGELOG.md](CHANGELOG.md)

### Rancher Versions

- Follows Helm chart versioning
- Update in `terraform/modules/rancher_cluster/main.tf`
- Test compatibility with Kubernetes version

## Documentation Standards

### README Files
- Start with clear project purpose
- Include quick start section
- Link to detailed documentation
- Show project structure

### Guide Documents
1. Title and overview
2. Prerequisites
3. Step-by-step instructions
4. Configuration examples
5. Verification steps
6. Troubleshooting
7. Related documentation

### Architecture Documentation
- Include system diagrams
- Describe components
- Document data flows
- List resource requirements

## Commit Messages

Use clear, descriptive commit messages:

```
feat: add new feature with description

fix: resolve issue description
docs: update documentation topic
refactor: restructure code without behavior change
test: add or update tests
chore: dependency updates, formatting

# Examples:
feat: update RKE2 version to v1.34.3+rke2r1
fix: resolve cloud-init network configuration issue
docs: add Rancher deployment documentation
```

## Questions?

Open an issue or discussion on GitHub - we're here to help!

---

**Thank you for contributing to Rancher Deploy!** 🙏
