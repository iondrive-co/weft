# Weft

Provisions a hardened Ubuntu server on **Vultr or AWS** using Terraform and
cloud-init.

You get a server with: an `ops` user (sudo, SSH key), firewall (UFW, SSH only),
hardened sshd (no passwords, no root login), base packages, and sensible OS
defaults. Root SSH access is removed after setup.

One variable -- `cloud` -- decides where it lands. Everything else (the scripts,
the cloud-init, `./weft.sh ssh`) works the same either way.


## Quick start

```bash
./setup.sh
```

That's the whole thing. Setup installs Terraform if it's missing, generates an
SSH key if you haven't got one, asks which cloud you want, opens the page where
the credentials live, waits while you paste them, shows you the regions and
sizes that cloud actually offers (with prices), verifies everything by planning
for real, and then offers to build the server and drop you into an SSH session
on it.

It's safe to re-run: it keeps whatever is already configured and only asks about
the rest. `./weft.sh` starts it for you if you skip it.

What it needs from you:

| Asked                        | Why                                                       |
|------------------------------|-----------------------------------------------------------|
| Vultr **or** AWS             | Which cloud to build on                                   |
| An API key / access key      | Only you can create one; setup opens the page and waits    |
| Region and size              | Picked from a live list, with prices                      |
| Hostname                     | Defaults to `weft`                                        |
| Lock SSH to your IP?         | Optional; setup already knows your address                |

Everything it learns goes into `.env` (credentials, chmod 600) and
`terraform.tfvars` (your choices). Both are gitignored, and plain
`./weft.sh apply` picks them up afterwards.

### If something's missing, setup handles it

- **No Terraform** -- offers to install it (APT repo on Linux, Homebrew on macOS)
- **No SSH key** -- offers to generate `~/.ssh/id_ed25519`
- **Vultr blocking your IP** -- Vultr's API refuses unlisted addresses. Setup
  reads the IP *Vultr* saw, copies it to your clipboard, opens the Access
  Control page, and polls until you've added it. No re-running anything.
- **Bad AWS credentials** -- caught while planning; setup says so and asks again
- **No default VPC in that AWS region** -- offers to install the AWS CLI into
  `~/.local` (no sudo) and create one, or opens the VPC console for you

## Vultr or AWS

Setup asks, and remembers. The difference:

|                  | `cloud = "vultr"`         | `cloud = "aws"`            |
|------------------|---------------------------|----------------------------|
| Default region   | `ams` (Amsterdam)         | `eu-central-1` (Frankfurt) |
| Default size     | `vc2-1c-1gb` (~$5/mo)     | `t3.micro`                 |
| Image            | Ubuntu 24.04 (os_id 2284) | newest Canonical 24.04 AMI |
| Network firewall | UFW only                  | UFW + security group       |
| Disk             | included in the plan      | 20 GB encrypted gp3        |
| Billing          | hourly, capped monthly    | per second, plus EBS       |

Everything else is identical: same `ops` user, same hardening, same
`./weft.sh ssh`.

**One state, one server.** Both clouds share a single Terraform state, so
switching cloud and applying *replaces* your server on the other one. To keep
one of each, give each a workspace:

```bash
terraform workspace new aws
./weft.sh apply -var="cloud=aws"
terraform workspace select default    # back to the Vultr one
```


## Usage

All commands go through `./weft.sh`:

| Command                | What it does                             |
|------------------------|------------------------------------------|
| `./weft.sh setup`      | Run the setup wizard (safe to re-run)    |
| `./weft.sh plan`       | Preview what will be created             |
| `./weft.sh apply`      | Create or update the server              |
| `./weft.sh destroy`    | Tear down the server                     |
| `./weft.sh ssh`        | SSH into the server as `ops`             |
| `./weft.sh ip`         | Print the server's IP address            |
| `./weft.sh cloud`      | Print configured vs provisioned cloud    |
| `./weft.sh status`     | Show current Terraform state             |
| `./weft.sh cloud-init` | Check cloud-init progress on server      |
| `./weft.sh test`       | Provision, check, destroy (smoke test)   |

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


## Testing

`./smoke-test.sh` provisions a server, asserts the box came up the way weft
intends, and destroys it again. About four minutes, a couple of cents:

```bash
./weft.sh test                                       # the cloud you set up
./smoke-test.sh vultr
./smoke-test.sh aws --keep -var="region=eu-west-1"   # leave it running
```

It uses `hostname=weft-smoke` so it can't collide with a real server, and always
destroys on exit unless you pass `--keep`. The checks cover cloud-init finishing
cleanly, the `ops` user and its sudo, all four sshd hardening settings, UFW's
state and default policy, every base package, timezone/NTP/swappiness,
unattended-upgrades being gone, `apt-get update` actually working through
whichever mirror was configured, and -- on AWS -- Amazon Time Sync and IMDSv2
being required.

Free checks that need no cloud account at all:

```bash
terraform validate
echo 'local.user_data' | terraform console -var="cloud=aws"   # render cloud-init
terraform plan -var="cloud=vultr"                             # no API calls from an empty state
```

An AWS `plan` does need credentials -- the provider verifies them with STS before
it will read anything.


## Customization

Override defaults by passing Terraform variables:

```bash
# Which cloud
./weft.sh plan -var="cloud=aws"

# Region (default: ams on Vultr, eu-central-1 on AWS)
./weft.sh plan -var="region=ewr"
./weft.sh plan -var="cloud=aws" -var="region=eu-west-1"

# Size (default: vc2-1c-1gb on Vultr, t3.micro on AWS)
./weft.sh plan -var="plan=vc2-1c-2gb"
./weft.sh plan -var="cloud=aws" -var="plan=t3.small"

# Lock SSH down to your own address
./weft.sh plan -var='ssh_allowed_cidrs=["203.0.113.4/32"]'

# Different hostname, different SSH key
./weft.sh plan -var="hostname=myserver"
./weft.sh plan -var="ssh_public_key_path=~/.ssh/other_key.pub"
```

Or create a `terraform.tfvars` file for persistent overrides (also gitignored):

```hcl
cloud    = "aws"
region   = "eu-west-1"
plan     = "t3.small"
hostname = "bigserver"
```

### All variables

| Variable              | Default                | Notes                                              |
|-----------------------|------------------------|----------------------------------------------------|
| `cloud`               | `vultr`                | `vultr` or `aws`                                   |
| `region`              | per-cloud              | Vultr region id, or AWS region                     |
| `plan`                | per-cloud              | Vultr plan id, or AWS instance type                |
| `hostname`            | `weft`                 | Hostname, and the name given to cloud resources    |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub`| Key installed for `ops`                            |
| `ssh_allowed_cidrs`   | `["0.0.0.0/0"]`        | IPv4 CIDRs allowed on port 22                      |
| `timezone`            | `Europe/Berlin`        |                                                    |
| `apt_mirror`          | per-cloud              | `""` keeps the image's own mirror                  |
| `vultr_api_key`       | -                      | Vultr only; usually from `.env`                    |
| `aws_profile`         | null                   | AWS only; shared-config profile to use             |
| `aws_architecture`    | `amd64`                | AWS only; `arm64` for Graviton (`t4g.*`) types     |
| `aws_root_volume_gb`  | `20`                   | AWS only; encrypted gp3 root volume                |
| `aws_subnet_id`       | null                   | AWS only; defaults to the default VPC's subnet     |

### Available regions

**Vultr** -- run `curl -s https://api.vultr.com/v2/regions | jq '.regions[].id'`,
or see https://www.vultr.com/api/#tag/region. Common ones:

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

**AWS** -- run `aws ec2 describe-regions --query 'Regions[].RegionName' --output text`,
or see https://docs.aws.amazon.com/general/latest/gr/rande.html. Common ones:

| Code             | Location      |
|------------------|---------------|
| `eu-central-1`   | Frankfurt     |
| `eu-west-1`      | Ireland       |
| `eu-north-1`     | Stockholm     |
| `us-east-1`      | N. Virginia   |
| `us-west-2`      | Oregon        |
| `ap-southeast-1` | Singapore     |
| `ap-southeast-2` | Sydney        |
| `ap-northeast-1` | Tokyo         |

### Available sizes

**Vultr** -- run `curl -s https://api.vultr.com/v2/plans | jq '.plans[] | {id, vcpu_count, ram, monthly_cost}'`.
Common ones:

| Plan            | Spec                 | Monthly |
|-----------------|----------------------|---------|
| `vc2-1c-1gb`    | 1 vCPU, 1 GB RAM     | $5      |
| `vc2-1c-2gb`    | 1 vCPU, 2 GB RAM     | $10     |
| `vc2-2c-4gb`    | 2 vCPU, 4 GB RAM     | $20     |
| `vc2-4c-8gb`    | 4 vCPU, 8 GB RAM     | $40     |

**AWS** -- billed per second, plus the EBS volume and any egress. Common ones:

| Instance type | Spec                 | Notes                          |
|---------------|----------------------|--------------------------------|
| `t3.micro`    | 2 vCPU, 1 GB RAM     | default; free tier eligible    |
| `t3.small`    | 2 vCPU, 2 GB RAM     |                                |
| `t3.medium`   | 2 vCPU, 4 GB RAM     |                                |
| `t4g.small`   | 2 vCPU, 2 GB RAM     | Arm; needs `aws_architecture=arm64` |


## What the server gets

Cloud-init runs on first boot and configures:

- **ops user**: sudo (NOPASSWD), your SSH key, bash shell
- **SSH hardening**: password auth off, root login off, X11 forwarding off
- **Firewall (UFW)**: deny all incoming, allow SSH (22/tcp) only, narrowed to
  `ssh_allowed_cidrs` if you set it
- **Unattended upgrades**: disabled (masked, purged, and pinned)
- **APT mirror**: a nearby cloud mirror on Vultr (reverting to the default if it
  doesn't respond); left alone on AWS, where the AMI already has a regional one
- **Packages**: curl, git, jq, ufw, net-tools, rsync, unzip, ca-certificates,
  vim-tiny, dnsutils, ncdu, lsof, tcpdump, atop
- **Timezone**: `Europe/Berlin` with NTP enabled (Amazon Time Sync on AWS)
- **Locale**: en_US.UTF-8
- **Swap**: vm.swappiness=1
- **Root access**: SSH authorized_keys removed

On AWS it additionally gets a security group allowing only inbound SSH, an
encrypted gp3 root volume, and IMDSv2 required for instance metadata.


## Doing it by hand

Setup covers all of this; it's here for reference, or for scripting weft into
something else.

`.env` holds the cloud choice and credentials, `terraform.tfvars` your sizing:

```bash
# .env
TF_VAR_cloud=aws                       # or vultr
TF_VAR_vultr_api_key=...               # Vultr
AWS_ACCESS_KEY_ID=AKIA...              # AWS: either a key pair...
AWS_SECRET_ACCESS_KEY=...
TF_VAR_aws_profile=myprofile           # ...or a ~/.aws profile
```

```hcl
# terraform.tfvars
region   = "eu-west-1"
plan     = "t3.small"
hostname = "weft"
```

AWS uses the standard credential chain, so a working `aws configure`, an
`AWS_PROFILE`, or an EC2 instance role all work with nothing in `.env`. The AWS
CLI itself is not required -- Terraform talks to the API directly.

Vultr keys come from **Account > API** at
https://my.vultr.com/settings/#settingsapi, and that page's **Access Control**
list must include your public IP or the API returns 401 to everything.

AWS keys come from
https://console.aws.amazon.com/iam/home#/security_credentials. The permissions
weft needs are EC2 read plus `RunInstances`, `TerminateInstances`,
`CreateSecurityGroup`, `AuthorizeSecurityGroupIngress/Egress`,
`DeleteSecurityGroup`, `ImportKeyPair` and `DeleteKeyPair`.

Then:

```bash
terraform init && terraform apply
```


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

Type `yes` when prompted. This destroys the server, plus the SSH key (and, on
AWS, the security group). Billing stops immediately on Vultr; on AWS the
instance and its EBS volume are both deleted.


## Troubleshooting

**`./weft.sh` says API key not set**
- Run `./setup.sh` again, or check that `.env` contains `TF_VAR_vultr_api_key=...`

**`terraform init` fails**
- Check your internet connection. Terraform needs to download the providers.

**Vultr: `apply` fails with 401 / "Unauthorized IP address"**
- Your public IP is not in Vultr's API access control list. Go to
  https://my.vultr.com/settings/#settingsapi, find **Access Control**, and add
  your IP (run `curl https://api.myip.com` to find it) or select **Allow All IPv4**.
  The setup script checks for this, but your IP may have changed since setup.

**Vultr: `apply` fails with "plan not found"**
- The plan ID might have changed. Run `curl -s https://api.vultr.com/v2/plans | jq '.plans[].id'` to list valid plans.

**AWS: "No valid credential sources found"**
- Terraform found no credentials. See [Credentials: AWS](#credentials-aws). If
  you put them in `.env`, note that only `./setup.sh` and `./weft.sh` load it --
  a bare `terraform apply` won't.

**AWS: "no matching EC2 VPC found"**
- The account has no default VPC in that region. Either create one
  (`aws ec2 create-default-vpc`) or point weft at a subnet:
  `-var="aws_subnet_id=subnet-0123456789abcdef0"`.

**AWS: instance type not supported / no AMI found**
- Graviton (`t4g.*`, `m7g.*`, ...) needs `-var="aws_architecture=arm64"`.
- Some older instance types don't exist in every region.

**AWS: `InvalidKeyPair.Duplicate`**
- A key pair named `weft` already exists in that region. Delete it, or use
  `-var="hostname=something-else"`.

**Changing anything in cloud-init.yml replaces the server**
- Both clouds treat user-data as immutable, so a template change means a new
  server with a new IP. Expected; there's nothing to migrate on a box this
  disposable.

**Can't SSH after apply**
- Wait 1-2 minutes for cloud-init. The server needs time to boot and configure.
- Check `./weft.sh ip` gives you a valid IP.
- Make sure you're using the right SSH key (default: `~/.ssh/id_ed25519`).
- On AWS, check `ssh_allowed_cidrs` still covers your current address.

**SSH works but then stops**
- Cloud-init restarts sshd and removes root's authorized_keys. If you were
  logged in as root, reconnect as `ops`.

**Want to see cloud-init logs**
- `./weft.sh ssh` then `sudo cat /var/log/cloud-init-output.log`
- Or: `./weft.sh cloud-init`
