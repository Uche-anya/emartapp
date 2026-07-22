# emartapp — deploying a forked microservices app on AWS

A fork of the `emartapp` microservices project, which I used as a base to practise infrastructure automation and CI/CD rather than application development. I didn't write the app. What I added was the Terraform to provision AWS, a GitHub Actions pipeline that builds and deploys on push, and a fair amount of learning about how quickly a badly-sized EC2 instance drains an AWS credit balance.

That last part turned out to be the most useful thing I got out of this, so it has its own section below.

Live at `http://51.20.24.243`.

## The app I inherited

Six containers, defined in [docker-compose.yaml](docker-compose.yaml):

- `client` (Angular, port 4200)
- `api` (Node, port 5000) with `emongo` (MongoDB 4) behind it
- `webapi` (Java, port 9000) with `emartdb` (MySQL 8.0.33) behind it
- `nginx` on port 80, doing the routing

Two databases and a JVM. That combination matters later.

## The infrastructure

```text
terraform/
├── main.tf          # provider, Ubuntu AMI lookup, default VPC, security group, EC2, EIP
├── variables.tf     # region, project name, instance type, key pair, SSH CIDR, repo URL
├── outputs.tf       # elastic IP, app URL, deploy role ARN
├── backend.tf       # S3 remote state with native lockfile
├── budget.tf        # $1 monthly budget alarm, kept separate on purpose
├── ssm.tf           # IAM instance profile so the box registers with SSM
├── github_oidc.tf   # OIDC provider + the role Actions assumes to deploy
├── user_data.sh     # installs git, Docker CE, compose plugin, 2 GB swapfile
└── terraform.tfvars # gitignored
```

[main.tf](terraform/main.tf) pulls the latest Ubuntu 24.04 AMI for whatever region you point it at, drops an instance into the default VPC with a 20 GB gp3 root volume, and attaches a security group opening 22 and 80 inbound with everything allowed out. Nothing exotic. `terraform apply` gets you a running box in about fifteen seconds.

State lives in S3, not on my laptop. The bucket is versioned and encrypted, and locking is the native `use_lockfile` that Terraform 1.10 added, so there's no DynamoDB table to run alongside it. The bucket gets created out of band rather than by this Terraform, because a config can't store its own state in a bucket it hasn't created yet, and putting the bucket under management would mean `destroy` trying to delete the thing it's reading state from. The bootstrap commands are in [backend.tf](terraform/backend.tf).

The Elastic IP came later and solved a specific annoyance. An auto-assigned public address changes every time the instance stops or gets replaced, so every resize meant updating the `EC2_HOST` secret and every stale value meant a deploy hanging on SSH until it timed out. An EIP attached to a running instance costs $0.005/hour, which is exactly what the auto-assigned address already cost, so the address became permanent for nothing.

## The pipeline

[.github/workflows/deploy.yml](.github/workflows/deploy.yml) runs three jobs on every push to `main`.

**`ci`** validates the Terraform before anything gets built: `fmt -check`, then `validate` against a backend-less init so it needs no AWS credentials, then tfsec. tfsec runs soft-fail on purpose, so it reports the open SSH port as a finding rather than blocking on a compromise that's already documented and on its way out.

**`build`** declares `needs: ci` and fans out across a three-way matrix, so `client`, `nodeapi`, and `javaapi` compile in parallel on GitHub's runners. Each image gets pushed to Docker Hub under two tags: the commit SHA, and `latest`. Layer caching goes through `type=gha`, so a change to `nodeapi` doesn't trigger a Maven rebuild of the Java service.

**`deploy`** declares `needs: build`. It used to SSH in with `appleboy/ssh-action` and a long-lived private key; it now assumes an AWS role through OIDC and drives the box over Systems Manager instead. It finds the instance by tag, sends one `AWS-RunShellScript` command, and polls the invocation for the result:

```bash
docker compose pull
docker compose up -d
```

No `--build` anywhere, and no inbound SSH. The command runs under SSM as root and hands the actual work to the `ubuntu` user, which owns the checkout and sits in the docker group, so file and container ownership stay consistent with every earlier deploy. The repo still gets cloned there because compose needs the YAML and `nginx/default.conf`, but that's all it's for now.

A `curl -fsS` loop against port 80 closes the job, retrying for five minutes. Before that existed the workflow went green whenever containers started, even if the app was throwing 500s.

Six secrets drive it now: `EC2_HOST` and `AWS_DEPLOY_ROLE`, plus `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` for the registry. `EC2_USER` and `EC2_SSH_KEY` are still present but no longer used by the pipeline; they go once the SSM path has a few green runs behind it. Nothing sensitive lands in the repo: [.gitignore](.gitignore) covers `*.pem`, `.env`, tfstate, and `terraform.tfvars`.

A cached run takes just under two minutes end to end.

## Things that broke

**SSH timed out from Actions.** The security group originally allowed port 22 from my home IP only, which was fine from my laptop and useless from GitHub's runners, since those come from a wide and shifting pool of GitHub-hosted addresses. The error was just `dial tcp <ip>:22: i/o timeout`, which took me a while to connect back to the CIDR rule. I opened 22 to `0.0.0.0/0` to get moving, which is the wrong fix and I left it visible in the code rather than quietly patching it. The proper fix is now built and described below: the pipeline drives the box over Systems Manager, so once that path has proven itself the port closes and the timeout can't recur, because there's no inbound SSH to time out on.

**No app directory on the instance.** `user_data.sh` installs Docker and Git but never clones anything, so the first pipeline run had nowhere to deploy into. The workflow now creates `~/microservices` and clones if the directory is missing.

**Docker permissions.** Standard fix, `usermod -aG docker ubuntu` in user_data, so the deploy script doesn't need sudo.

**Builds failing on a secret that didn't exist yet.** I pushed the new pipeline before saving the Docker Hub credentials, so all three build jobs died at the login step. The useful part was watching `needs: build` do its job: the deploy was skipped rather than half-applied, and the server never saw a broken release. The failed check stays pinned to that commit even after a later run passes, which looks alarming and means nothing.

## The cost problem

I sized the instance at `c7i-flex.large` without thinking about it. In `eu-north-1` that's $0.09077/hour, about $65 a month for a portfolio app nobody visits.

What actually cost me the money wasn't the type so much as leaving it up. `c7i-flex.large` is the priciest thing on the list my account is allowed to launch; `t3.small` sits on the same list at $0.52 a day. Running the expensive one around the clock, for an app receiving no traffic, is four times the burn for capacity that only matters during a build.

I only noticed because I went looking. Here's the monthly usage on the account:

| Month | Usage |
| --- | --- |
| Feb 2026 | $0.41 |
| Mar 2026 | $0.58 |
| Apr 2026 | $0.72 |
| May 2026 | $16.11 |
| Jun 2026 | $33.29 |
| Jul 2026 (to the 20th) | $20.86 |

Around $72 of usage in total, all of it absorbed by free-tier credits, so nothing has hit my card. But credits are a balance that drains, not an allowance that resets, and I hadn't set up a single alarm to tell me when it ran dry. The jump in May lines up with a kops cluster I spun up for a different project and left running for two months.

Two costs I didn't know about until I looked:

Every public IPv4 address bills at $0.005/hour whether or not it's doing anything, a change AWS made in February 2024. July's VPC line was $4.54, which is almost entirely that. And stopping an instance doesn't stop the EBS charge — the volume keeps billing while the instance sits there doing nothing.

## What "free tier" actually means here

AWS changed the free tier in July 2025. The old one handed you 750 hours a month of `t2.micro` or `t3.micro` across twelve months, and those specific types were the free thing. The new plan, which my account is on, gives you a credit balance over six months instead. As of 20 July I had **$47.87 left with 35 days**, expiring 22 August, whichever hit first.

I assumed that meant no restrictions, since credits are just money and money spends anywhere. Wrong, and I found out by trying. Swapping to a `t3.medium` (2 vCPU, 4 GiB, half the hourly rate of what I'd been running) got rejected outright:

```text
InvalidParameterCombination: The specified instance type is not eligible
for Free Tier.
```

Both constraints apply at once. There's an allowlist of types, enforced at `RunInstances`, and everything you launch off it still bills against credits. The allowlist for `eu-north-1`:

| Type | RAM | $/day | Days on $47.87 |
| --- | --- | --- | --- |
| t3.micro, t4g.micro | 1 GiB | $0.26 | well past the deadline |
| t3.small | 2 GiB | $0.52 | past the deadline |
| t4g.small (ARM) | 2 GiB | $0.41 | past the deadline |
| **c7i-flex.large** | **4 GiB** | **$2.18** | ~20, dry in early August |
| m7i-flex.large | 8 GiB | $2.44 | ~19 |

Worth pulling for your own region and account, since it isn't the list I expected:

```bash
aws ec2 describe-instance-types \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,MemoryInfo.SizeInMiB]' --output text
```

Which reframes the original mistake. `c7i-flex.large` was never a rule I broke; it's on the allowlist, and that's precisely why nothing stopped me. It's just the most expensive entry on it, and I left it running.

Credits expire on the date whether I spend them or not, which flips the usual instinct. Hoarding them wastes them.

The box currently runs `c7i-flex.large`, sized back when the pipeline still compiled on the server and 4 GiB was the floor. That constraint is gone now that GitHub does the building, so dropping to `t3.small` takes the burn from $2.18 a day to $0.52. That resize is the one change I'm holding until the SSM deploy has a green run, since I'd rather not change two things at once and then guess which one broke. There's a 2 GB swapfile in [user_data.sh](terraform/user_data.sh) to absorb whatever spikes remain.

## What I hardened afterwards

The first working version was one server, one SSH key, one local state file, and no idea what it cost. Everything here was walking that back.

**Budget alarm.** [budget.tf](terraform/budget.tf) is a $1 monthly budget with both an actual and a forecasted alert, kept in its own file so `terraform destroy` on the app can't take the thing that warns me about spending down with it. The forecasted alert is the one that earns its keep: it fires days before the money actually lands, off the account's own projection. This should have been the first thing I built rather than the fourth.

**Remote state.** The state file moved off my laptop into a versioned, encrypted S3 bucket with native locking. Losing a local state file means Terraform no longer knows what it owns and can't cleanly update or destroy any of it; versioning turns a corrupted state from unrecoverable into an annoyance.

**SSM instead of SSH.** [ssm.tf](terraform/ssm.tf) gives the instance an IAM profile carrying `AmazonSSMManagedInstanceCore`, so its agent registers with Systems Manager and the deploy runs through the AWS API. [github_oidc.tf](terraform/github_oidc.tf) is the other half: Actions assumes a role by proving which repo and branch it's running from, so there's no static AWS key anywhere. The role's condition pins it to `main` of this one repo, and its permissions are two lines: send one `AWS-RunShellScript` command to this one instance, and read the result. Once a deploy over that path goes green, port 22 closes and `EC2_SSH_KEY` gets deleted.

**A CI gate.** The `ci` job runs `terraform fmt -check`, `validate`, and tfsec before any image is built, with `build` depending on it. It's an infrastructure gate, not an application one. The honest gap: there are no real app tests to run. `nodeapi`'s test script is the default `exit 1` placeholder and the Angular tests need a browser, so claiming a test stage I don't have would be worse than admitting the hole.

## Still to do

**Close port 22 and resize**, together, right after the first green SSM deploy. Same apply flips the ingress rule to drop 22 and changes the instance type to `t3.small`.

Further out, and deliberately not on the free tier: the repo already carries a [kkartchart/](kkartchart/) Helm chart from upstream that nobody's using, so EKS is the obvious next step. EKS charges $0.10/hour for the control plane before a single node exists, which is around $73 a month, so that one waits until it's a deliberate spend rather than a surprise. Same reasoning for an ALB at roughly $16 a month, and for Prometheus and Grafana, which won't fit comfortably alongside everything else. TLS is more achievable: Caddy in front with a DuckDNS subdomain gets automatic Let's Encrypt certs for nothing, and kills the awkward "use HTTP, not HTTPS" caveat below.

## Running it

```bash
git clone https://github.com/Uche-anya/emartapp.git
cd emartapp/terraform
```

Create `terraform.tfvars` locally (it's gitignored):

```hcl
aws_region       = "eu-north-1"
project_name     = "emartapp"
instance_type    = "c7i-flex.large"    # must be free-tier-eligible, see above
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

Generate a Docker Hub access token with Read & Write permissions, then add these secrets under Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `EC2_HOST` | the Elastic IP from `terraform output` |
| `AWS_DEPLOY_ROLE` | the `github_deploy_role_arn` output |
| `DOCKERHUB_USERNAME` | your Docker Hub username, also the image namespace |
| `DOCKERHUB_TOKEN` | the access token |

Push to `main` and the workflow takes over. The app comes up at `http://<elastic-ip>` on plain HTTP; there's no certificate, so don't type `https://`.

The deploy authenticates through OIDC, so there's no AWS key to store. If you're bringing this up from scratch on a fresh account, the state bucket has to exist before the first `terraform init`; the two `aws s3api` commands for that are at the top of [backend.tf](terraform/backend.tf).

Rolling back means setting `TAG` in `.env` on the instance to an earlier commit SHA and running `docker compose up -d`. Every commit that ever passed CI is still sitting in Docker Hub.

**Set a billing alarm before you apply any of this.** I didn't, and while it cost me nothing in the end, that was luck rather than anything I did right.

## Stack

Terraform, AWS EC2, Elastic IP, security groups, IAM, Systems Manager, OIDC, S3 remote state, AWS Budgets, Ubuntu 24.04, Docker, Docker Compose, Docker Hub, GitHub Actions, tfsec, nginx, Node, Java, MongoDB, MySQL.
