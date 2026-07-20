# emartapp — deploying a forked microservices app on AWS

A fork of the `emartapp` microservices project, which I used as a base to practise infrastructure automation and CI/CD rather than application development. I didn't write the app. What I added was the Terraform to provision AWS, a GitHub Actions pipeline that deploys on push, and a fair amount of learning about how quickly a badly-sized EC2 instance drains an AWS credit balance.

That last part turned out to be the most useful thing I got out of this, so it has its own section below.

## The app I inherited

Six containers, defined in [docker-compose.yaml](docker-compose.yaml):

- `client` (Angular, port 4200)
- `api` (Node, port 5000) with `emongo` (MongoDB 4) behind it
- `webapi` (Java, port 9000) with `emartdb` (MySQL 8.0.33) behind it
- `nginx` on port 80, doing the routing

Two databases and a JVM. That combination matters later.

## What I built

```
terraform/
├── main.tf          # provider, Ubuntu AMI lookup, default VPC, security group, EC2
├── variables.tf     # region, project name, instance type, key pair, SSH CIDR, repo URL
├── outputs.tf       # public IP, app URL, SSH command
├── user_data.sh     # installs git, Docker CE, compose plugin; adds ubuntu to docker group
└── terraform.tfvars # gitignored
```

[main.tf](terraform/main.tf) pulls the latest Ubuntu 24.04 AMI for whatever region you point it at, drops an instance into the default VPC with a 20 GB gp3 root volume, and attaches a security group opening 22 and 80 inbound with everything allowed out. Nothing exotic. It works, and `terraform apply` gets you a running app in about four minutes.

The pipeline lives in [.github/workflows/deploy.yml](.github/workflows/deploy.yml). Every push to `main` triggers `appleboy/ssh-action`, which SSHes into the box, clones the repo if it isn't there yet, hard-resets to `origin/main`, then tears down and rebuilds the stack:

```bash
git fetch origin main
git reset --hard origin/main
docker compose down || true
docker compose up -d --build
```

Three secrets drive it: `EC2_HOST`, `EC2_USER`, and `EC2_SSH_KEY` holding the private key contents. The `.pem` never goes near the repo; [.gitignore](.gitignore) covers `*.pem`, `.env`, tfstate, and `terraform.tfvars`.

## Things that broke

**SSH timed out from Actions.** The security group originally allowed port 22 from my home IP only, which was fine from my laptop and useless from GitHub's runners, since those come from a wide and shifting pool of GitHub-hosted addresses. The error was just `dial tcp <ip>:22: i/o timeout`, which took me a while to connect back to the CIDR rule. I opened 22 to `0.0.0.0/0` to get moving. That's the wrong fix and I've left it visible in the code rather than quietly patching it, because the right fix is in the roadmap below.

**No app directory on the instance.** `user_data.sh` installs Docker and Git but never clones anything, so the first pipeline run had nowhere to deploy into. The workflow now creates `~/microservices` and clones if the directory is missing.

**Docker permissions.** Standard fix, `usermod -aG docker ubuntu` in user_data, so the deploy script doesn't need sudo.

## The cost problem

I sized the instance at `c7i-flex.large` without thinking about it. In `eu-north-1` that's about $0.086/hour, so roughly $62 a month for something serving a portfolio app that nobody visits.

I only noticed because I went looking. Here's the monthly usage on the account:

| Month | Usage |
|---|---|
| Feb 2026 | $0.41 |
| Mar 2026 | $0.58 |
| Apr 2026 | $0.72 |
| May 2026 | $16.11 |
| Jun 2026 | $33.29 |
| Jul 2026 (to the 20th) | $20.86 |

Around $72 of usage in total, all of it absorbed by free-tier credits, so nothing has hit my card. But credits are a balance that drains, not an allowance that resets, and I hadn't set up a single alarm to tell me when it ran dry. The jump in May lines up with a kops cluster I spun up for a different project and left running for two months.

Two costs I didn't know about until I looked:

Every public IPv4 address bills at $0.005/hour whether or not it's doing anything, a change AWS made in February 2024. July's VPC line was $4.54, which is almost entirely that. And stopping an instance doesn't stop the EBS charge — the volume keeps billing while the instance sits there doing nothing.

I've since terminated the emartapp instance. The orphaned security group and a stale tfstate are still sitting there, which is its own small lesson about local state files.

## Why the free tier doesn't fit this app

The free-tier instance in `eu-north-1` is `t3.micro`: 2 vCPU, **1 GB RAM**. Note that `t2.micro` isn't offered in Stockholm.

The current pipeline runs `docker compose up -d --build` on the server, meaning the EC2 box compiles the Angular client and runs a Maven build for the Java API. A Maven build alone wants more than 1 GB. Even ignoring the build, MySQL 8 and MongoDB and a JVM all resident at once won't fit in 1 GB with room to spare.

So the app doesn't shrink to fit the free tier. The deployment approach has to change instead.

## Work to be done

Ordered by what I'd tackle first.

**1. Move builds off the server.** Build images in GitHub Actions, push to Docker Hub (free, unlimited public repos, and a better fit here than ECR whose free tier caps at 500 MB), then have EC2 only run `docker compose pull && docker compose up -d`. No compiler ever touches the instance. Deploys drop from minutes to seconds, and rolling back becomes a matter of pointing at the previous tag.

**2. Resize to `t3.micro` and add swap.** Requires the change above to be viable at all. `t3` instances default to `unlimited` CPU credit mode, which bills you for sustained bursts, so `credit_specification { cpu_credits = "standard" }` goes in alongside. A 2 GB swapfile in user_data as a safety net.

**3. Budget alarm at $1.** An `aws_budgets_budget` resource in its own file so `terraform destroy` on the app doesn't take the alarm with it. Given I ran a $62/month instance without noticing, this should honestly have been first.

**4. Close port 22.** Replace the SSH action with AWS Systems Manager Session Manager, using an instance profile carrying `AmazonSSMManagedInstanceCore` and OIDC auth from Actions instead of a long-lived key. That removes the `0.0.0.0/0` rule and the `EC2_SSH_KEY` secret together.

**5. Remote state.** [terraform.tfstate](terraform/terraform.tfstate) currently lives on my laptop, so losing it means losing the ability to manage or destroy anything it tracks. S3 backend with `use_lockfile` (Terraform 1.10+ handles locking natively now, no DynamoDB table needed). Costs nothing under the S3 free tier.

**6. A CI stage before the CD stage.** Right now a broken `nodeapi` reaches production untested. `terraform fmt -check`, `validate`, tfsec, a build, whatever tests exist. The deploy job `needs:` it.

**7. Health check after deploy.** The workflow currently reports success as long as the containers start, even if the app returns 500s. A `curl -f` retry loop against port 80 as the final step.

Further out, and deliberately not on the free tier: the repo already carries a [kkartchart/](kkartchart/) Helm chart from upstream that nobody's using, so EKS is the obvious next step. EKS charges $0.10/hour for the control plane before a single node exists, which is around $73 a month, so that one waits until it's a deliberate spend rather than a surprise. Same reasoning for an ALB at roughly $16 a month, and for Prometheus and Grafana, which won't fit in 1 GB anyway. TLS is more achievable: Caddy in front with a DuckDNS subdomain gets automatic Let's Encrypt certs for nothing, and kills the awkward "use HTTP, not HTTPS" caveat below.

## Running it

```bash
git clone https://github.com/Uche-anya/emartapp.git
cd emartapp/terraform
```

Create `terraform.tfvars` locally (it's gitignored):

```hcl
aws_region       = "eu-north-1"
project_name     = "emartapp"
instance_type    = "t3.micro"          # not c7i-flex.large, see above
key_name         = "your-key-pair-name"
ssh_allowed_cidr = "your.ip.here/32"
app_repo_url     = "https://github.com/Uche-anya/emartapp.git"
```

Then:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

Add `EC2_HOST`, `EC2_USER` (`ubuntu`), and `EC2_SSH_KEY` under Settings → Secrets and variables → Actions in the GitHub repo. Push to `main` and the workflow takes over.

The app comes up at `http://<ec2-public-ip>` on plain HTTP. There's no certificate, so don't type `https://`.

**Set a billing alarm before you apply this.** I didn't, and while it cost me nothing in the end, that was luck rather than anything I did right.

## Stack

Terraform, AWS EC2, security groups, Ubuntu 24.04, Docker, Docker Compose, GitHub Actions, SSH, nginx, Node, Java, MongoDB, MySQL.
