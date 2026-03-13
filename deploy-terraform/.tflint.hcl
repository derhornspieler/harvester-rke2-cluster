# =============================================================================
# TFLint Configuration
# =============================================================================
# Linting rules for Terraform files in this repository.
#
# This config focuses on general Terraform best practices. Provider-specific
# rulesets (e.g., tflint-ruleset-aws) are NOT included because this project
# uses Rancher and Harvester providers which don't have TFLint rulesets.
# =============================================================================

config {
  # Apply module inspection for local modules (none in this repo currently)
  call_module_type = "local"
}

# --- Core Terraform Rules ---

# Enforce that all terraform blocks specify required_version
rule "terraform_required_version" {
  enabled = true
}

# Enforce that all provider blocks come from required_providers
rule "terraform_required_providers" {
  enabled = true
}

# Enforce consistent naming conventions (snake_case)
rule "terraform_naming_convention" {
  enabled = true
}

# Warn on deprecated syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Warn on unused declarations
rule "terraform_unused_declarations" {
  enabled = true
}

# Enforce type declarations on variables
rule "terraform_typed_variables" {
  enabled = true
}

# Warn on variables with no description
rule "terraform_documented_variables" {
  enabled = true
}

# Warn on outputs with no description
rule "terraform_documented_outputs" {
  enabled = true
}

# Warn on using terraform workspace in non-default configurations
rule "terraform_workspace_remote" {
  enabled = true
}

# Standard module structure check
rule "terraform_standard_module_structure" {
  enabled = false  # Not a published module, so this doesn't apply
}
