mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

mock_provider "random" {}

run "a_single_availability_zone_is_rejected" {
  command = plan

  variables {
    availability_zone_count = 1
  }

  expect_failures = [var.availability_zone_count]
}

run "the_controller_runs_exactly_one_task" {
  command = plan

  assert {
    condition     = module.controller.name == "jenkins-controller"
    error_message = "The controller service should be named after the architecture."
  }

  assert {
    condition     = module.monitoring.alarm_count == 5
    error_message = "The load balancer and the controller service should both be alarmed on."
  }
}

run "without_a_domain_the_entry_point_is_plain_http" {
  command = plan

  assert {
    condition     = length(module.http_listener) == 1 && length(module.https_listener) == 0
    error_message = "With no certificate to attach, the only listener can be the plain HTTP one."
  }

  assert {
    condition     = length(module.http_redirect) == 0
    error_message = "There is nothing to redirect to when no HTTPS listener exists."
  }

  assert {
    condition     = length(module.certificate) == 0 && length(module.zone) == 0
    error_message = "No certificate or hosted zone should be created without a domain name."
  }
}

run "a_domain_moves_the_entry_point_to_https_and_redirects" {
  command = plan

  variables {
    domain_name = "ci.example.com"
  }

  assert {
    condition     = length(module.https_listener) == 1 && length(module.http_redirect) == 1
    error_message = "A domain should produce an HTTPS listener and a redirect from HTTP."
  }

  assert {
    condition     = length(module.http_listener) == 0
    error_message = "The plain HTTP target listener should be replaced by the redirect."
  }

  assert {
    condition     = output.url == "https://ci.example.com"
    error_message = "The reported URL should use the supplied domain over HTTPS."
  }

  assert {
    condition     = length(module.records[0].ids) == 1
    error_message = "A domain should create one apex alias record to the load balancer."
  }
}

run "every_aws_api_the_controller_uses_has_an_interface_endpoint" {
  command = plan

  assert {
    condition     = length(module.endpoints) == 6
    error_message = "The controller reaches ECR, Logs, Secrets Manager and SSM privately, which takes six endpoints."
  }
}

run "several_allowed_cidr_blocks_still_plan" {
  command = plan

  variables {
    allowed_cidr_blocks = ["203.0.113.0/24", "198.51.100.0/24", "192.0.2.0/24"]
  }
}

run "no_accelerator_by_default" {
  command = plan

  assert {
    condition     = length(module.accelerator) == 0
    error_message = "The accelerator is opt-in and should not exist by default."
  }

  assert {
    condition     = length(output.accelerator_ip_sets) == 0
    error_message = "With no accelerator there are no anycast addresses to report."
  }
}

run "enabling_the_accelerator_creates_it" {
  command = plan

  variables {
    enable_global_accelerator = true
  }

  assert {
    condition     = length(module.accelerator) == 1
    error_message = "Setting the flag should create the accelerator."
  }
}

run "the_controller_state_is_backed_up" {
  command = plan

  assert {
    condition     = module.backup_vault.name == "jenkins"
    error_message = "The backup vault should be named after the architecture."
  }
}

run "a_budget_amount_creates_a_budget_notifying_the_alarm_topic" {
  command = plan

  variables {
    monthly_budget = "1500"
  }

  assert {
    condition     = length(module.budget) == 1
    error_message = "Supplying a monthly amount should create a budget."
  }
}

run "no_budget_amount_creates_no_budget" {
  command = plan

  assert {
    condition     = length(module.budget) == 0
    error_message = "A budget should only be created when a monthly amount is supplied."
  }
}

run "an_alarm_email_subscribes_to_the_topic" {
  command = plan

  variables {
    alarm_email = "platform@example.com"
  }

  assert {
    condition     = length(module.alerts.subscription_arns) == 1
    error_message = "Supplying an address should subscribe it to the alarm topic."
  }
}
