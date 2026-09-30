# terraform-aws-architecture-jenkins

Terraform module for a Jenkins controller that nobody has to administer —
a Fargate task holding its state on EFS, behind a load balancer and a web
ACL, launching its build agents as containers that exist only for the
duration of a build.

## Cost

Nothing here is free-tier. The standing charges, at the defaults, are a
NAT gateway per availability zone, an application load balancer, a
Fargate task running continuously for the controller, the web ACL, and
**twelve interface endpoint ENIs** — six services across two zones, each
billed hourly. EFS bills per gigabyte stored, which for a controller's
history is small. Build agents bill per second only while a build runs,
which is the point of running them on Fargate.

The interface endpoints are the surprising line item. They exist so the
controller reaches ECR, CloudWatch Logs, Secrets Manager, and SSM without
its traffic leaving the AWS network — a security and reliability choice
that costs real money. Dropping to a single availability zone would halve
them and is not worth the loss of recoverability. See AWS's
[PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/) and
[Fargate pricing](https://aws.amazon.com/fargate/pricing/) pages.

## Design

Every resource comes from a published module in this family, resolved
from the Terraform Registry under a `~> 1.0` version constraint. This
module contains no `resource` blocks of its own; it is wiring and nothing
else.

### What it builds

| Layer | Contents |
|---|---|
| Network | VPC across `availability_zone_count` zones with public, controller, and storage tiers, an S3 gateway endpoint, and flow logs |
| Private access | Interface endpoints for `ecr.api`, `ecr.dkr`, `logs`, `secretsmanager`, `ssm`, and `ssmmessages` |
| Entry | Internet-facing load balancer restricted to `allowed_cidr_blocks`, a regional web ACL with AWS's common rule set and an IP rate limit, HTTPS when a domain is supplied |
| Controller | One Fargate task, no public IP, in the private controller tier, registered with the load balancer |
| State | Encrypted EFS file system with a mount target per zone, and an access point pinning `JENKINS_HOME` to uid/gid 1000 |
| Agents | A cluster, a security group, subnets, and an execution role — the controller launches the tasks itself |
| Cross-cutting | Customer managed KMS key, Secrets Manager secret, log groups, SNS topic, CloudWatch alarms, daily AWS Backup plan, optional budget |

### "Highly available" means recovery, not redundancy

This is the most important thing to understand before relying on it.
**A Jenkins controller cannot run as two copies.** `JENKINS_HOME` is a
single-writer directory; two controllers mounting the same EFS file
system will corrupt each other's state. So `desired_count` is 1 and
raising it is not an improvement, it is an outage.

What this architecture actually gives you is **fast, unattended
recovery**:

- ECS restarts a failed task automatically, in whichever availability
  zone is healthy, with no human involved.
- EFS has a mount target in every zone, so the controller's state
  survives the loss of the zone it was running in.
- The load balancer spans zones and drains the dead target on its own.
- The backup plan and EFS's own daily backups mean state survives
  deletion as well as failure.

The honest number is a recovery time of a minute or two — the time for
ECS to place a new task and for Jenkins to start its JVM — not the zero
of an active-active service. If a build system that never pauses is a
requirement, the answer is several independent controllers split by team
or workload, not one controller made redundant.

### Nearly zero management

There is no EC2 instance here, so there is no operating system to patch,
no autoscaling group to size, and no SSH key to rotate. The controller is
a container image; upgrading Jenkins is a change to `controller_image`
and a new task. Agents exist only while a build runs, so there is no idle
fleet to maintain or scale down.

**Agents are launched by Jenkins, not by Terraform.** The Jenkins ECS
plugin creates an agent task whenever a build needs one and stops it
afterwards, which is why this module creates no agent service. What it
does instead is produce everything the plugin needs to be configured
with, as outputs: `cluster_arn`, `agent_subnet_ids`,
`agent_security_group_id`, `agent_execution_role_arn`, `agent_cpu`, and
`agent_memory`. Fill those into the plugin's cloud configuration and the
loop closes.

### Security

The controller has no public IP and lives in a private tier. Only the
load balancer reaches it, and only on 8080. The security groups form a
chain that is worth reading in one line each: the internet reaches the
load balancer, the load balancer reaches the controller, agents reach the
controller on the agent port, and only the controller reaches EFS on
2049. Agents accept no inbound traffic at all.

Because every AWS API the controller uses has an interface endpoint, its
calls to ECR, Logs, Secrets Manager, and SSM never traverse the internet
or the NAT gateway. Administrator credentials live in Secrets Manager and
are injected as a container secret rather than an environment variable
baked into the task definition. EFS is encrypted with a customer managed
key and mounted with transit encryption on.

**`allowed_cidr_blocks` defaults to `0.0.0.0/0`, and you should change
it.** A Jenkins controller reachable from the whole internet is a
standing invitation, and the web ACL in front of it is a mitigation
rather than an answer. Narrow it to your office and VPN ranges.

### The path to global

`enable_global_accelerator` puts two static anycast addresses in front of
the load balancer, routed to it over AWS's own backbone rather than the
public internet. For a controller serving engineers on other continents
that is the single highest-value change, and it requires nothing else to
be restructured.

Beyond that, the expansion that actually works is **agents in more
regions, not controllers**. The controller stays in one region holding
one `JENKINS_HOME`; additional regions contribute capacity by running
agents that dial home to it. That needs a network path — a transit
gateway or VPC peering, both of which this family builds — and the agent
port open across it. What does not work is a second controller sharing
state, for the single-writer reason above.

### Things it deliberately does not do

- **The log groups are not encrypted with the customer managed key.**
  CloudWatch Logs needs an explicit grant in the key policy, and
  `terraform-aws-kms-key` creates keys with AWS's default policy. Passing
  the key here would fail at apply, so it is left off rather than shipped
  broken. Extend the key policy and add it.
- **The default image comes from Docker Hub**, which rate-limits
  unauthenticated pulls and can therefore fail a cold start at exactly
  the wrong moment. The fix is to hold the controller image in your own
  registry: build it, push it to a repository from
  [`terraform-aws-ecr-repository`](https://github.com/kn47ytv9mv/terraform-aws-ecr-repository),
  and point `controller_image` at that repository's URL. Doing so also
  lets you pin a digest rather than a tag, which is what makes a
  controller restart reproducible. A pull-through cache — which would
  mirror Docker Hub automatically instead of requiring you to build —
  is a different AWS resource that this family does not yet cover.
- **Without `domain_name` the entry point is plain HTTP.** There is no
  certificate to attach, so credentials would cross the network in the
  clear. Acceptable to evaluate; not acceptable to use.
- **The initial administrator secret is created empty.** Populate it
  before the first start; the controller has nothing to read otherwise.

## Usage

```hcl
module "jenkins" {
  source  = "kn47ytv9mv/architecture-jenkins/aws"
  version = "~> 1.0"

  name                = "ci"
  allowed_cidr_blocks = ["203.0.113.0/24"]
  alarm_email         = "platform@example.com"
}
```

A production controller on its own domain, reachable globally, with a
larger controller and a budget:

```hcl
module "jenkins" {
  source = "github.com/kn47ytv9mv/terraform-aws-architecture-jenkins"

  name                    = "ci"
  region                  = "eu-west-1"
  availability_zone_count = 3

  domain_name         = "ci.example.com"
  allowed_cidr_blocks = ["203.0.113.0/24", "198.51.100.0/24"]

  controller_image  = "jenkins/jenkins:lts-jdk21"
  controller_cpu    = 2048
  controller_memory = 4096

  agent_cpu    = 2048
  agent_memory = 4096

  enable_global_accelerator = true

  alarm_email    = "platform@example.com"
  monthly_budget = "1500"

  tags = {
    Environment = "production"
  }
}
```

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.11 |
| aws | ~> 6.61 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| region | Region every resource in this architecture is created in. | `"us-east-1"` | no |
| name | Name prefix applied to every resource, so one account can hold several copies of this architecture without collision. | `"jenkins"` | no |
| vpc_cidr | IPv4 range for the VPC. Each tier carves a /24 out of it per availability zone. | `"10.0.0.0/16"` | no |
| availability_zone_count | Availability zones to spread across. Two is the minimum for a load balancer AWS will accept, and it is what lets the controller restart in a surviving zone. | `2` | no |
| controller_image | Container image the controller runs. Pin a digest rather than a tag for a reproducible controller. | `"jenkins/jenkins:lts-jdk21"` | no |
| controller_cpu | Fargate CPU units for the controller. 1024 is one vCPU. | `1024` | no |
| controller_memory | Fargate memory for the controller, in mebibytes. Jenkins is JVM-based and unhappy below 2048. | `2048` | no |
| agent_cpu | Fargate CPU units advertised for build agents. The controller launches agents itself, so this is recorded as an output rather than used to create anything. | `1024` | no |
| agent_memory | Fargate memory advertised for build agents, in mebibytes. | `2048` | no |
| allowed_cidr_blocks | IPv4 ranges permitted to reach the load balancer. Defaults to the whole internet, which is almost never what a build system should accept. | `["0.0.0.0/0"]` | no |
| domain_name | Domain the controller is served on. Setting it creates a public hosted zone, an ACM certificate, and an alias record, and moves the listener to HTTPS. | `null` | no |
| enable_global_accelerator | Whether to front the load balancer with a Global Accelerator, giving two static anycast addresses routed over AWS's own backbone. | `false` | no |
| efs_backup | Whether EFS keeps its own automatic daily backups, in addition to the AWS Backup plan. | `true` | no |
| log_retention_days | Days the controller's logs are retained. Build logs are the audit trail for what shipped. | `90` | no |
| alarm_email | Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it. | `null` | no |
| monthly_budget | Monthly spend in USD to alarm on, as a string. If null, no budget is created. | `null` | no |
| tags | A map of tags applied to every resource in the architecture. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| url | Address the controller is reached on. |
| load_balancer_dns_name | DNS name of the load balancer in front of the controller. |
| cluster_arn | ARN of the ECS cluster. Give this to the Jenkins ECS plugin. |
| agent_subnet_ids | Subnets the Jenkins ECS plugin should launch build agents into. |
| agent_security_group_id | Security group the Jenkins ECS plugin should attach to build agents. |
| agent_execution_role_arn | Execution role the Jenkins ECS plugin should give agent tasks. |
| agent_cpu | Fargate CPU units to configure for agents in the Jenkins ECS plugin. |
| agent_memory | Fargate memory to configure for agents in the Jenkins ECS plugin. |
| state_file_system_id | The EFS file system holding `JENKINS_HOME`. |
| admin_credentials_secret_arn | Secrets Manager secret the controller reads its initial administrator credentials from. |
| accelerator_ip_sets | Static anycast addresses of the Global Accelerator. Empty unless enabled. |
| alerts_topic_arn | ARN of the topic every alarm in this architecture notifies. |
| alarm_count | Number of CloudWatch alarms the monitoring baseline created. |
| name_servers | Name servers for the hosted zone, to delegate the domain to. |

## License

MIT — see [LICENSE.md](LICENSE.md).
