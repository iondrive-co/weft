#!/usr/bin/env bash
set -euo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WEFT_DIR"

echo "=== Weft Setup ==="
echo ""

# --- Check for terraform ---

if command -v terraform &>/dev/null; then
  echo "[ok] Terraform is installed: $(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1)"
else
  echo "[!!] Terraform is not installed."
  echo ""

  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Install it now? This will add the HashiCorp APT repo and install terraform."
    echo ""
    read -rp "Install terraform? [y/N] " install_tf
    if [[ "$install_tf" =~ ^[Yy]$ ]]; then
      echo ""
      echo "Installing terraform..."
      curl -fsSL https://apt.releases.hashicorp.com/gpg | \
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
      sudo apt-get update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/hashicorp.list -o Dir::Etc::sourceparts=/dev/null
      sudo apt-get install -y -qq terraform
      echo "[ok] Terraform installed: $(terraform version -json | jq -r '.terraform_version')"
    else
      echo ""
      echo "You'll need to install terraform before continuing."
      echo "See: https://developer.hashicorp.com/terraform/install"
      exit 1
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v brew &>/dev/null; then
      echo "Install it now with Homebrew?"
      echo ""
      read -rp "Install terraform? [y/N] " install_tf
      if [[ "$install_tf" =~ ^[Yy]$ ]]; then
        brew install terraform
        echo "[ok] Terraform installed: $(terraform version -json | jq -r '.terraform_version')"
      else
        echo ""
        echo "You'll need to install terraform before continuing."
        echo "  brew install terraform"
        exit 1
      fi
    else
      echo "Install Homebrew first: https://brew.sh"
      echo "Then: brew install terraform"
      exit 1
    fi
  else
    echo "See: https://developer.hashicorp.com/terraform/install"
    exit 1
  fi
fi

echo ""

# --- Check for SSH key ---

SSH_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"

if [ -f "$SSH_KEY_PATH" ]; then
  echo "[ok] SSH key found: $SSH_KEY_PATH"
else
  echo "[!!] No SSH key found at $SSH_KEY_PATH"
  echo ""
  echo "Generate one now?"
  echo ""
  read -rp "Generate SSH key? [y/N] " gen_key
  if [[ "$gen_key" =~ ^[Yy]$ ]]; then
    ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519" -N ""
    echo "[ok] SSH key created: $SSH_KEY_PATH"
  else
    echo ""
    echo "You'll need an SSH key. Generate one with:"
    echo "  ssh-keygen -t ed25519"
    exit 1
  fi
fi

echo ""

# --- Configure Vultr API key ---

if [ -f .env ] && grep -q 'TF_VAR_vultr_api_key=' .env 2>/dev/null; then
  echo "[ok] Vultr API key is configured in .env"
else
  echo "[!!] Vultr API key not configured."
  echo ""
  echo "Get your API key from: https://my.vultr.com/settings/#settingsapi"
  echo "(Enable the API if needed, and make sure your IP is in the access control list)"
  echo ""
  read -rp "Paste your Vultr API key: " api_key
  if [ -z "$api_key" ]; then
    echo "No API key provided. You can set it later in .env:"
    echo "  echo 'TF_VAR_vultr_api_key=YOUR_KEY' > .env"
    exit 1
  fi
  echo "TF_VAR_vultr_api_key=${api_key}" > .env
  chmod 600 .env
  echo "[ok] API key saved to .env (chmod 600)"
fi

echo ""

# --- Check Vultr API access (IP whitelist) ---

source .env
export TF_VAR_vultr_api_key

my_ip=$(curl -fsSL https://api.myip.com 2>/dev/null | jq -r '.ip' 2>/dev/null || echo "")

echo "Checking Vultr API access..."
api_response=$(curl -fsSL -w "\n%{http_code}" -H "Authorization: Bearer ${TF_VAR_vultr_api_key}" \
  https://api.vultr.com/v2/account 2>/dev/null || echo "")
http_code=$(echo "$api_response" | tail -1)

if [ "$http_code" = "200" ]; then
  echo "[ok] Vultr API is accessible"
elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
  echo "[!!] Vultr API rejected the request (HTTP $http_code)."
  echo ""
  echo "This usually means your IP is not in the API access control list."
  if [ -n "$my_ip" ]; then
    echo "Your current IP is: $my_ip"
  fi
  echo ""
  echo "Fix this:"
  echo "  1. Go to https://my.vultr.com/settings/#settingsapi"
  echo "  2. Under 'Access Control', add your IP${my_ip:+ ($my_ip)} or select 'Allow All IPv4'"
  echo "  3. Run ./setup.sh again"
  exit 1
else
  echo "[!!] Could not reach Vultr API (HTTP $http_code). Check your internet connection and API key."
  exit 1
fi

echo ""

# --- Terraform init ---

echo "Running terraform init..."
echo ""

source .env
export TF_VAR_vultr_api_key

terraform init

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  ./weft.sh plan     # Preview what will be created"
echo "  ./weft.sh apply    # Create the server"
echo "  ./weft.sh ssh      # SSH in (wait ~2min after apply)"
