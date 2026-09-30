module "network" {
  source  = "kn47ytv9mv/vpc/aws"
  version = "~> 1.0"

  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count

  subnets = {
    public     = { public = true }
    controller = { nat_gateway_access = true }
    storage    = {}
  }

  gateway_endpoints = {
    s3 = {}
  }

  flow_logs = [
    {
      destination_arn  = module.flow_log_group.arn
      destination_type = "cloud-watch-logs"
    },
  ]

  tags = var.tags
}

module "key" {
  source  = "kn47ytv9mv/kms-key/aws"
  version = "~> 1.0"

  description = "${var.name} controller state, logs, and secrets"

  tags = var.tags
}

module "key_alias" {
  source  = "kn47ytv9mv/kms-alias/aws"
  version = "~> 1.0"

  name          = var.name
  target_key_id = module.key.arn
}

module "flow_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/vpc/${var.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

module "controller_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/ecs/${var.name}-controller"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

module "log_bucket" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket = "${var.name}-logs"

  tags = var.tags
}

module "alb_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-alb"
  vpc_id      = module.network.vpc_id
  description = "Entry point for ${var.name}, reachable only from allowed_cidr_blocks."

  ingress_rules = concat(
    [for cidr in var.allowed_cidr_blocks : {
      description = "HTTPS from ${cidr}"
      ip_protocol = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_ipv4   = cidr
    }],
    [for cidr in var.allowed_cidr_blocks : {
      description = "HTTP from ${cidr}"
      ip_protocol = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_ipv4   = cidr
    }],
  )

  egress_rules = [
    { description = "All outbound", ip_protocol = "-1", from_port = -1, to_port = -1, cidr_ipv4 = "0.0.0.0/0" },
  ]

  tags = var.tags
}

module "agent_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-agents"
  vpc_id      = module.network.vpc_id
  description = "Build agents for ${var.name}. Agents open connections outward and accept none."

  egress_rules = [
    { description = "All outbound", ip_protocol = "-1", from_port = -1, to_port = -1, cidr_ipv4 = "0.0.0.0/0" },
  ]

  tags = var.tags
}

module "controller_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-controller"
  vpc_id      = module.network.vpc_id
  description = "Controller for ${var.name}, reachable from the load balancer and from its own agents."

  ingress_rules = [
    { description = "Web UI from the load balancer", ip_protocol = "tcp", from_port = 8080, to_port = 8080, referenced_security_group_id = module.alb_security_group.id },
    { description = "Agent protocol from build agents", ip_protocol = "tcp", from_port = 50000, to_port = 50000, referenced_security_group_id = module.agent_security_group.id },
  ]

  egress_rules = [
    { description = "All outbound", ip_protocol = "-1", from_port = -1, to_port = -1, cidr_ipv4 = "0.0.0.0/0" },
  ]

  tags = var.tags
}

module "storage_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-storage"
  vpc_id      = module.network.vpc_id
  description = "EFS mount targets for ${var.name}, reachable only from the controller."

  ingress_rules = [
    { description = "NFS from the controller", ip_protocol = "tcp", from_port = 2049, to_port = 2049, referenced_security_group_id = module.controller_security_group.id },
  ]

  tags = var.tags
}

module "endpoint_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-endpoints"
  vpc_id      = module.network.vpc_id
  description = "Interface endpoints for ${var.name}, reachable from the controller and its agents."

  ingress_rules = [
    { description = "HTTPS from the controller", ip_protocol = "tcp", from_port = 443, to_port = 443, referenced_security_group_id = module.controller_security_group.id },
    { description = "HTTPS from build agents", ip_protocol = "tcp", from_port = 443, to_port = 443, referenced_security_group_id = module.agent_security_group.id },
  ]

  tags = var.tags
}

module "endpoints" {
  source  = "kn47ytv9mv/vpc-endpoint/aws"
  version = "~> 1.0"

  for_each = toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager", "ssm", "ssmmessages"])

  vpc_id             = module.network.vpc_id
  service            = each.value
  subnet_ids         = module.network.subnet_ids["controller"]
  security_group_ids = [module.endpoint_security_group.id]

  tags = var.tags
}

module "state" {
  source  = "kn47ytv9mv/efs/aws"
  version = "~> 1.0"

  creation_token = "${var.name}-controller"
  encrypted      = true
  kms_key_id     = module.key.arn
  backup_policy  = var.efs_backup ? "enabled" : "disabled"

  subnet_ids         = module.network.subnet_ids["storage"]
  security_group_ids = [module.storage_security_group.id]

  tags = var.tags
}

module "state_access_point" {
  source  = "kn47ytv9mv/efs-access-point/aws"
  version = "~> 1.0"

  file_system_id = module.state.id

  posix_user = {
    uid = 1000
    gid = 1000
  }

  root_directory = {
    path = "/jenkins-home"

    creation_info = {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = var.tags
}

module "admin_credentials" {
  source  = "kn47ytv9mv/secretsmanager-secret/aws"
  version = "~> 1.0"

  name        = "${var.name}/controller"
  description = "Initial administrator credentials for ${var.name}, read by the controller at startup rather than baked into its task definition."
  kms_key_id  = module.key.arn

  tags = var.tags
}

module "execution_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-execution"
  principal_identifiers = ["ecs-tasks.amazonaws.com"]
  managed_policy_arns   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [module.admin_credentials.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [module.key.arn]
      },
    ]
  })

  tags = var.tags
}

module "controller_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-controller"
  principal_identifiers = ["ecs-tasks.amazonaws.com"]

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "ecs:StopTask", "ecs:DescribeTasks", "ecs:ListTasks", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:ListClusters", "ecs:DescribeClusters", "ecs:ListContainerInstances"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [module.execution_role.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"]
        Resource = [module.state.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${module.controller_log_group.arn}:*"]
      },
    ]
  })

  tags = var.tags
}

module "cluster" {
  source  = "kn47ytv9mv/ecs-cluster/aws"
  version = "~> 1.0"

  name               = var.name
  container_insights = true

  tags = var.tags
}

module "target_group" {
  source  = "kn47ytv9mv/alb-target-group/aws"
  version = "~> 1.0"

  name              = "${var.name}-controller"
  vpc_id            = module.network.vpc_id
  port              = 8080
  protocol          = "HTTP"
  target_type       = "ip"
  health_check_path = "/login"

  tags = var.tags
}

module "alb" {
  source  = "kn47ytv9mv/alb/aws"
  version = "~> 1.0"

  name               = "${var.name}-alb"
  internal           = false
  subnet_ids         = module.network.subnet_ids["public"]
  security_group_ids = [module.alb_security_group.id]

  access_logs_bucket = module.log_bucket.bucket
  access_logs_prefix = "alb"

  tags = var.tags
}

module "certificate" {
  source  = "kn47ytv9mv/acm-certificate/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  domain_name = var.domain_name

  tags = var.tags
}

module "https_listener" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  load_balancer_arn = module.alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = module.certificate[0].arn
  target_group_arn  = module.target_group.arn

  tags = var.tags
}

module "http_redirect" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  load_balancer_arn = module.alb.arn
  port              = 80
  protocol          = "HTTP"
  type              = "redirect"

  redirect = {
    port        = "443"
    protocol    = "HTTPS"
    status_code = "HTTP_301"
  }

  tags = var.tags
}

module "http_listener" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"
  count   = var.domain_name == null ? 1 : 0

  load_balancer_arn = module.alb.arn
  port              = 80
  protocol          = "HTTP"
  target_group_arn  = module.target_group.arn

  tags = var.tags
}

module "firewall" {
  source  = "kn47ytv9mv/wafv2-web-acl/aws"
  version = "~> 1.0"

  name           = "${var.name}-alb"
  scope          = "REGIONAL"
  default_action = "allow"

  visibility_config = {
    metric_name = "${var.name}-alb"
  }

  rules_json = jsonencode([
    {
      Name     = "common"
      Priority = 0
      Statement = {
        ManagedRuleGroupStatement = {
          VendorName = "AWS"
          Name       = "AWSManagedRulesCommonRuleSet"
        }
      }
      OverrideAction = { None = {} }
      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "${var.name}-common"
        SampledRequestsEnabled   = true
      }
    },
    {
      Name     = "rate-limit"
      Priority = 1
      Statement = {
        RateBasedStatement = {
          Limit            = 2000
          AggregateKeyType = "IP"
        }
      }
      Action = { Block = {} }
      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "${var.name}-rate-limit"
        SampledRequestsEnabled   = true
      }
    },
  ])

  tags = var.tags
}

module "firewall_association" {
  source  = "kn47ytv9mv/wafv2-web-acl-association/aws"
  version = "~> 1.0"

  resource_arn = module.alb.arn
  web_acl_arn  = module.firewall.arn
}

module "controller" {
  source  = "kn47ytv9mv/ecs-service/aws"
  version = "~> 1.0"

  name                     = "${var.name}-controller"
  cluster_arn              = module.cluster.arn
  launch_type              = "FARGATE"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = var.controller_cpu
  memory = var.controller_memory

  execution_role_arn = module.execution_role.arn
  task_role_arn      = module.controller_role.arn

  desired_count      = 1
  subnet_ids         = module.network.subnet_ids["controller"]
  assign_public_ip   = false
  security_group_ids = [module.controller_security_group.id]

  volumes = [
    {
      name            = "jenkins-home"
      file_system_id  = module.state.id
      access_point_id = module.state_access_point.id
    },
  ]

  load_balancer = {
    container_name   = "jenkins"
    container_port   = 8080
    target_group_arn = module.target_group.arn
  }

  container_definitions = jsonencode([
    {
      name      = "jenkins"
      image     = var.controller_image
      essential = true

      portMappings = [
        { containerPort = 8080, protocol = "tcp" },
        { containerPort = 50000, protocol = "tcp" },
      ]

      mountPoints = [
        { sourceVolume = "jenkins-home", containerPath = "/var/jenkins_home", readOnly = false },
      ]

      environment = [
        { name = "JAVA_OPTS", value = "-Djenkins.install.runSetupWizard=false -Dhudson.slaves.NodeProvisioner.initialDelay=0" },
        { name = "JENKINS_SLAVE_AGENT_PORT", value = "50000" },
      ]

      secrets = [
        { name = "JENKINS_ADMIN_CREDENTIALS", valueFrom = module.admin_credentials.arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = module.controller_log_group.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "controller"
        }
      }
    },
  ])

  tags = var.tags
}

module "accelerator" {
  source  = "kn47ytv9mv/global-accelerator/aws"
  version = "~> 1.0"
  count   = var.enable_global_accelerator ? 1 : 0

  name = var.name

  flow_logs_enabled   = true
  flow_logs_s3_bucket = module.log_bucket.bucket
  flow_logs_s3_prefix = "accelerator"

  listeners = {
    web = {
      protocol    = "TCP"
      port_ranges = [{ from_port = 443, to_port = 443 }]

      endpoint_groups = {
        (var.region) = {
          health_check_path = "/login"

          endpoint_configurations = [
            { endpoint_id = module.alb.arn, weight = 100 },
          ]
        }
      }
    }
  }

  tags = var.tags
}

module "zone" {
  source  = "kn47ytv9mv/route53-zone/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  name = var.domain_name

  tags = var.tags
}

module "records" {
  source  = "kn47ytv9mv/route53-record/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  records = {
    apex = {
      zone_id = module.zone[0].id
      name    = var.domain_name
      type    = "A"

      alias = {
        name    = module.alb.dns_name
        zone_id = module.alb.zone_id
      }
    }
  }
}

module "alerts" {
  source  = "kn47ytv9mv/sns-topic/aws"
  version = "~> 1.0"

  name         = "${var.name}-alerts"
  display_name = "${var.name} alerts"

  subscriptions = var.alarm_email != null ? [
    { protocol = "email", endpoint = var.alarm_email },
  ] : []

  tags = var.tags
}

module "monitoring" {
  source  = "kn47ytv9mv/monitoring-baseline/aws"
  version = "~> 1.0"

  name_prefix   = var.name
  alarm_actions = [module.alerts.arn]
  ok_actions    = [module.alerts.arn]

  load_balancers = {
    web = { arn_suffix = module.alb.arn_suffix }
  }

  ecs_services = {
    controller = { cluster_name = module.cluster.name, service_name = module.controller.name }
  }

  tags = var.tags
}

module "backup_vault" {
  source  = "kn47ytv9mv/backup-vault/aws"
  version = "~> 1.0"

  name        = var.name
  kms_key_arn = module.key.arn

  tags = var.tags
}

module "backup_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-backup"
  principal_identifiers = ["backup.amazonaws.com"]
  managed_policy_arns   = ["arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"]

  tags = var.tags
}

module "backup_plan" {
  source  = "kn47ytv9mv/backup-plan/aws"
  version = "~> 1.0"

  name = var.name

  rules = [
    {
      rule_name         = "daily"
      target_vault_name = module.backup_vault.name
      schedule          = "cron(0 4 * * ? *)"
      lifecycle         = { delete_after = 35 }
    },
  ]

  selections = [
    {
      name         = "controller-state"
      iam_role_arn = module.backup_role.arn
      resources    = [module.state.arn]
    },
  ]

  tags = var.tags
}

module "budget" {
  source  = "kn47ytv9mv/budget/aws"
  version = "~> 1.0"
  count   = var.monthly_budget != null ? 1 : 0

  name         = "${var.name}-monthly"
  limit_amount = var.monthly_budget

  notifications = [
    {
      threshold                 = 80
      notification_type         = "FORECASTED"
      subscriber_sns_topic_arns = [module.alerts.arn]
    },
  ]

  tags = var.tags
}

output "url" {
  description = "Address the controller is reached on. Uses the domain when one was supplied, and the load balancer's own name otherwise."
  value       = var.domain_name != null ? "https://${var.domain_name}" : "http://${module.alb.dns_name}"
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer in front of the controller."
  value       = module.alb.dns_name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster. Give this to the Jenkins ECS plugin as the cluster it launches agents into."
  value       = module.cluster.arn
}

output "agent_subnet_ids" {
  description = "Subnets the Jenkins ECS plugin should launch build agents into."
  value       = module.network.subnet_ids["controller"]
}

output "agent_security_group_id" {
  description = "Security group the Jenkins ECS plugin should attach to build agents. It reaches the controller on port 50000 and accepts no inbound traffic."
  value       = module.agent_security_group.id
}

output "agent_execution_role_arn" {
  description = "Execution role the Jenkins ECS plugin should give agent tasks, so they can pull images and write logs."
  value       = module.execution_role.arn
}

output "agent_cpu" {
  description = "Fargate CPU units to configure for agents in the Jenkins ECS plugin."
  value       = var.agent_cpu
}

output "agent_memory" {
  description = "Fargate memory to configure for agents in the Jenkins ECS plugin."
  value       = var.agent_memory
}

output "state_file_system_id" {
  description = "The EFS file system holding JENKINS_HOME."
  value       = module.state.id
}

output "admin_credentials_secret_arn" {
  description = "Secrets Manager secret the controller reads its initial administrator credentials from. Populate it before the first start."
  value       = module.admin_credentials.arn
}

output "accelerator_ip_sets" {
  description = "Static anycast addresses of the Global Accelerator. Empty unless enable_global_accelerator is set."
  value       = var.enable_global_accelerator ? module.accelerator[0].ip_sets : []
}

output "alerts_topic_arn" {
  description = "ARN of the topic every alarm in this architecture notifies."
  value       = module.alerts.arn
}

output "alarm_count" {
  description = "Number of CloudWatch alarms the monitoring baseline created."
  value       = module.monitoring.alarm_count
}

output "name_servers" {
  description = "Name servers for the hosted zone, to delegate the domain to. Empty when no domain_name was supplied."
  value       = var.domain_name != null ? module.zone[0].name_servers : []
}
