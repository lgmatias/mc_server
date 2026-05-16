# mc_server

A personal project for running **Minecraft servers on AWS** — built so I can
spin up any Minecraft version on demand, switch between versions freely, and
**not pay for storage I'm not using**.

World data lives in **S3** (cheap — roughly $0.02/GB-month) as the single source
of truth. An EC2 server and its EBS volume can be torn down completely when idle
and recreated later — the world is pulled back from S3 on the next boot. So you
pay for an EBS volume only while a server actually exists, and switching versions
is just a matter of deploying a different stack.

> Personal project, provided as-is with no warranty. It deploys real AWS
> resources that cost real money.

## What it does

- **Any Minecraft version** — vanilla Java Edition, from alpha/beta builds
  through the current release. The server JAR and the matching Java runtime
  (Amazon Corretto 8 / 17 / 21 / 25) are selected automatically per version.
- **PGM** — competitive PvP on SportPaper (Minecraft 1.8.9) as a second flavour.
- **S3 as the source of truth for worlds** — `server-stop.sh` pushes the world
  to S3; every boot pulls it back. Tear a server down, redeploy it weeks later
  in any region, and the world follows.
- **One stack per version** — `mc-1-20-4`, `mc-1-8-9`, … each fully independent.
- **SSM-only admin** — no SSH keys and no open SSH port; shell access is via AWS
  Systems Manager Session Manager.
- **Architecture-aware** — any EC2 instance type, x86 or Graviton/ARM; the AMI
  and JVM heap are sized automatically for whatever type you pick.
- **Dynamic DNS** — each launch points a Route 53 record at the instance's
  current public IP so players can connect by hostname (record name is set in
  the scripts; `--no-ip` skips it).

## How it works

- `cloudformation/` — the infrastructure: a per-version vanilla EC2 stack, the
  PGM stack, and a shared S3 bucket for world data.
- `scripts/` — thin wrappers around the AWS CLI to deploy, start, stop, back up,
  and tear down servers.
- Lifecycle: each EC2 server has a retained EBS data volume; the world syncs
  to/from `s3://mc-worlds-<account>/<version>/`. **Stop** a server to pause
  compute billing; **terminate** it to drop the EBS volume entirely.

## Prerequisites

- An AWS account, and the **AWS CLI v2** configured with credentials.
- A Bash environment — Linux, macOS, WSL, or Git Bash on Windows.

## Quick start

```bash
# 1. One-time: create the shared S3 bucket for world data
./scripts/deploy-worlds-bucket.sh

# 2. Deploy a server (one stack per version)
./scripts/deploy.sh 1.20.4
#    ...or PGM:                       ./scripts/deploy.sh pgm
#    ...or choose instance/size/region: ./scripts/deploy.sh 1.20.4 t4g.small 20 us-east-1

# 3. Connect — the deploy output prints the public IP (port 25565)

# 4. Stop when done — saves the world to S3 and pauses compute billing
./scripts/server-stop.sh 1.20.4

# 5. Start it again later — the world is restored from S3 on boot
./scripts/server-start.sh 1.20.4

# 6. Tear it down entirely — deletes the stack AND its EBS volume.
#    The world stays safe in S3; redeploy any time to get it back.
./scripts/terminate.sh 1.20.4
```

## Scripts

| Script | Purpose |
|---|---|
| `deploy-worlds-bucket.sh` | Create the shared S3 world-data bucket (run once per account). |
| `deploy.sh` | Deploy/update a vanilla (`<version>`) or PGM (`pgm`) server stack. |
| `server-start.sh` | Start a stopped server's EC2 instance. |
| `server-stop.sh` | Save the world to S3, then stop the instance (pauses compute cost). |
| `terminate.sh` | Delete one stack and its retained EBS volume (the world stays in S3). |
| `backup-world.sh` | Push a point-in-time world snapshot to S3. |
| `cleanup.sh` | Account-wide teardown across all regions. |

Open a shell on a running server:
`aws ssm start-session --target <instance-id>`

## Cost notes

- **Running** — EC2 compute plus a public-IPv4 charge while the instance is up.
- **Stopped** — you pay only for the EBS volume (~$2–3/month for the default size).
- **Terminated** — next to nothing: just the world sitting in S3 (~$0.02/GB-month).

A small or Graviton instance keeps an always-on server in the low tens of dollars
per month; stopping it when idle drops that to a few dollars.

## Sharing access with someone else

The [`share-access/`](share-access/) folder is an onboarding kit for handing
control of an existing deployment to another person — or for setting up a second
machine of your own. It has a `setup.sh` that installs the tooling and writes the
AWS profile, a Windows Git Bash launcher, and a `SECRETS.template`. See
[share-access/README.md](share-access/README.md).

Real credentials go in `share-access/SECRETS`, which is git-ignored and never
pushed. The template is committed so a fresh clone knows what to fill in.

## Layout

```
cloudformation/   CloudFormation templates — vanilla, PGM, worlds bucket
scripts/          deploy / start / stop / terminate / backup / cleanup
share-access/     onboarding kit for sharing access to a deployment
```
