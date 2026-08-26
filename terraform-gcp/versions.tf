terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Talks to the Google Cloud API - creates the VM, firewall rules, etc.
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }

    # Generates an SSH keypair for us, so we don't have to create one by
    # hand and paste it in.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # Writes the generated private key to a local file.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    # Once k3s is running on the VM, this talks to it - same provider as
    # in terraform/, just pointed at a different kubeconfig file.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}