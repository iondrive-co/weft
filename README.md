# Weft

Provisions a hardened Ubuntu server on Vultr using Terraform and cloud-init.

You get a server with: an `ops` user (sudo, SSH key), firewall (UFW, SSH only),
hardened sshd (no passwords, no root login), base packages, and sensible OS
defaults. Root SSH access is removed after setup.


## Prerequisites

You need three things:

1. **Terraform** installed on your machine
2. **A Vultr account** with an API key
3. **An SSH key** on your machine

If you don't have these yet, `./setup.sh` will walk you through it.


## Quick start

```bash
# 1. Run setup (installs terraform, configures API key, runs terraform init)
./setup.sh

# 2. Preview what will be created
./weft.sh plan

# 3. Create the server
./weft.sh apply

# 4. SSH in (wait ~2 minutes for cloud-init to finish)
./weft.sh ssh
```


## Setup in detail

### Install Terraform

The setup script handles this, but if you prefer to do it manually:

**Debian/Ubuntu:**
```bash
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
```

**macOS:**
```bash
brew install terraform
```

### Get a Vultr API key

1. Log into https://my.vultr.com
2. Go to **Account > API** (or visit https://my.vultr.com/settings/#settingsapi)
3. Click **Enable API** if not already enabled
4. Copy the API key
5. **Important: whitelist your IP.** Under **Access Control**, add your public IP
   or select **Allow All IPv4**. The API will reject all requests from IPs not on
   this list with a 401 error. You can find your IP with `curl https://api.myip.com`

### SSH key

If you don't have one at `~/.ssh/id_ed25519.pub`, generate one:

```bash
ssh-keygen -t ed25519
```

Press enter to accept defaults. No passphrase required (but recommended).

### Configure

The setup script creates a `.env` file with your API key. You can also create
it manually:

```bash
echo 'TF_VAR_vultr_api_key=YOUR_KEY_HERE' > .env
```

This file is gitignored and never committed.

### Initialize

```bash
./weft.sh init
```

This downloads the Vultr Terraform provider. Only needed once.


## Usage

All commands go through `./weft.sh`:

| Command               | What it does                        |
|------------------------|-------------------------------------|
| `./weft.sh init`       | Initialize Terraform (run once)     |
| `./weft.sh plan`       | Preview what will be created        |
| `./weft.sh apply`      | Create or update the server         |
| `./weft.sh destroy`    | Tear down the server                |
| `./weft.sh ssh`        | SSH into the server as `ops`        |
| `./weft.sh ip`         | Print the server's IP address       |
| `./weft.sh status`     | Show current Terraform state        |
| `./weft.sh cloud-init` | Check cloud-init progress on server |

### After `apply`

The server takes about 1-2 minutes to boot and run cloud-init. You can check
progress:

```bash
# Check if cloud-init is done (run this after SSH works)
./weft.sh cloud-init
```

If SSH doesn't work immediately after apply, wait a minute -- cloud-init is
still configuring the server. Once it's done, root SSH is disabled and only the
`ops` user can log in.


## Customization

Override defaults by passing Terraform variables:

```bash
# Different region (default: ams = Amsterdam)
./weft.sh plan -var="region=ewr"

# Bigger server (default: vc2-1c-1gb = 1 vCPU, 1GB RAM, $5/mo)
./weft.sh plan -var="plan=vc2-1c-2gb"

# Different hostname
./weft.sh plan -var="hostname=myserver"

# Different SSH key
./weft.sh plan -var="ssh_public_key_path=~/.ssh/other_key.pub"
```

Or create a `terraform.tfvars` file for persistent overrides:

```hcl
region   = "ewr"
plan     = "vc2-2c-4gb"
hostname = "bigserver"
```

### Available regions

Run `curl -s https://api.vultr.com/v2/regions | jq '.regions[].id'` to list
them, or see https://www.vultr.com/api/#tag/region. Common ones:

| Code  | Location          |
|-------|-------------------|
| `ams` | Amsterdam         |
| `ewr` | New Jersey        |
| `fra` | Frankfurt         |
| `lhr` | London            |
| `nrt` | Tokyo             |
| `ord` | Chicago           |
| `sea` | Seattle           |
| `sgp` | Singapore         |

### Available plans

Run `curl -s https://api.vultr.com/v2/plans | jq '.plans[] | {id, vcpu_count, ram, monthly_cost}'`
to list them. Common ones:

| Plan            | Spec                 | Monthly |
|-----------------|----------------------|---------|
| `vc2-1c-1gb`    | 1 vCPU, 1 GB RAM     | $5      |
| `vc2-1c-2gb`    | 1 vCPU, 2 GB RAM     | $10     |
| `vc2-2c-4gb`    | 2 vCPU, 4 GB RAM     | $20     |
| `vc2-4c-8gb`    | 4 vCPU, 8 GB RAM     | $40     |


## What the server gets

Cloud-init runs on first boot and configures:

- **ops user**: sudo (NOPASSWD), your SSH key, bash shell
- **SSH hardening**: password auth off, root login off, X11 forwarding off
- **Firewall (UFW)**: deny all incoming, allow SSH (22/tcp) only
- **Unattended upgrades**: disabled (masked, purged, and pinned)
- **APT mirror**: set to Vultr's regional mirror
- **Packages**: curl, git, jq, ufw, net-tools, rsync, unzip, ca-certificates,
  vim-tiny, dnsutils, ncdu, lsof, tcpdump, atop
- **Timezone**: Europe/Berlin with NTP enabled
- **Locale**: en_US.UTF-8
- **Swap**: vm.swappiness=1
- **Root access**: SSH authorized_keys removed


## PyCharm

Run configurations are included in `.run/`. After opening the project in
PyCharm, they appear in the Run dropdown:

- **Weft: Setup** -- runs `./setup.sh`
- **Weft: Plan** -- preview changes
- **Weft: Apply** -- create/update server
- **Weft: SSH** -- connect to server
- **Weft: Destroy** -- tear down server


## Tearing down

```bash
./weft.sh destroy
```

Type `yes` when prompted. This destroys the server and removes the SSH key from
Vultr. You stop being billed immediately.


## Troubleshooting

**`./weft.sh` says API key not set**
- Run `./setup.sh` again, or check that `.env` contains `TF_VAR_vultr_api_key=...`

**`terraform init` fails**
- Check your internet connection. Terraform needs to download the Vultr provider.

**`terraform apply` fails with 401 / "Unauthorized IP address"**
- Your public IP is not in Vultr's API access control list. Go to
  https://my.vultr.com/settings/#settingsapi, find **Access Control**, and add
  your IP (run `curl https://api.myip.com` to find it) or select **Allow All IPv4**.
  The setup script checks for this, but your IP may have changed since setup.

**`terraform apply` fails with "plan not found"**
- The plan ID might have changed. Run `curl -s https://api.vultr.com/v2/plans | jq '.plans[].id'` to list valid plans.

**Can't SSH after apply**
- Wait 1-2 minutes for cloud-init. The server needs time to boot and configure.
- Check `./weft.sh ip` gives you a valid IP.
- Make sure you're using the right SSH key (default: `~/.ssh/id_ed25519`).

**SSH works but then stops**
- Cloud-init restarts sshd and removes root's authorized_keys. If you were
  logged in as root, reconnect as `ops`.

**Want to see cloud-init logs**
- `./weft.sh ssh` then `sudo cat /var/log/cloud-init-output.log`
- Or: `./weft.sh cloud-init`
