########################################################################################################################
# Resource group
########################################################################################################################

module "resource_group" {
  source  = "terraform-ibm-modules/resource-group/ibm"
  version = "1.2.0"
  # if an existing resource group is not set (null) create a new one using prefix
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

##############################################################################
# Key Protect Instance + Key (used to encrypt bucket)
##############################################################################

locals {
  key_ring_name = "${var.prefix}-cloud-logs"
  key_name      = "${var.prefix}-cloud-logs-key"
}

module "key_protect" {
  source            = "terraform-ibm-modules/kms-all-inclusive/ibm"
  version           = "4.21.8"
  resource_group_id = module.resource_group.resource_group_id
  region            = var.region
  resource_tags     = var.resource_tags
  keys = [
    {
      key_ring_name = local.key_ring_name
      keys = [
        {
          key_name = local.key_name
        }
      ]
    }
  ]
  key_protect_instance_name = "${var.prefix}-kp"
}

##############################################################################
# Event Notification
##############################################################################

module "event_notification_1" {
  source            = "terraform-ibm-modules/event-notifications/ibm"
  version           = "1.19.14"
  resource_group_id = module.resource_group.resource_group_id
  name              = "${var.prefix}-en-1"
  tags              = var.resource_tags
  plan              = "standard"
  service_endpoints = "public"
  region            = var.region
}

module "event_notification_2" {
  source            = "terraform-ibm-modules/event-notifications/ibm"
  version           = "1.19.14"
  resource_group_id = module.resource_group.resource_group_id
  name              = "${var.prefix}-en-2"
  tags              = var.resource_tags
  plan              = "standard"
  service_endpoints = "public"
  region            = var.region
}

##############################################################################
# COS instance + buckets
##############################################################################

module "cos" {
  source            = "terraform-ibm-modules/cos/ibm"
  version           = "8.21.8"
  resource_group_id = module.resource_group.resource_group_id
  cos_instance_name = "${var.prefix}-cos"
  cos_tags          = var.resource_tags
  create_cos_bucket = false
}

locals {
  logs_bucket_name    = "${var.prefix}-logs-data"
  metrics_bucket_name = "${var.prefix}-metrics-data"
}

module "buckets" {
  source  = "terraform-ibm-modules/cos/ibm//modules/buckets"
  version = "8.21.8"
  bucket_configs = [
    {
      bucket_name                   = local.logs_bucket_name
      kms_encryption_enabled        = true
      region_location               = var.region
      resource_instance_id          = module.cos.cos_instance_id
      kms_guid                      = module.key_protect.kms_guid
      kms_key_crn                   = module.key_protect.keys["${local.key_ring_name}.${local.key_name}"].crn
      skip_iam_authorization_policy = false
    },
    {
      bucket_name                   = local.metrics_bucket_name
      kms_encryption_enabled        = true
      region_location               = var.region
      resource_instance_id          = module.cos.cos_instance_id
      kms_guid                      = module.key_protect.kms_guid
      kms_key_crn                   = module.key_protect.keys["${local.key_ring_name}.${local.key_name}"].crn
      skip_iam_authorization_policy = true # Auth policy created in first bucket
    }
  ]
}

########################################################################################################################
# Cloud Logs
########################################################################################################################

#
# Developer tips:
#   - Call the local module / modules in the example to show how they can be consumed
#   - include the actual module source as a code comment like below so consumers know how to consume from correct location
#

locals {
  cloud_logs_instance_name = "${var.prefix}-cloud-logs"
}

module "cloud_logs" {
  source = "../../"
  # delete line above and use below syntax to pull module source from hashicorp when consuming this module
  # source    = "terraform-ibm-modules/cloud-logs/ibm"
  # version   = "X.Y.Z" # Replace "X.X.X" with a release version to lock into a specific release
  resource_group_id = module.resource_group.resource_group_id
  region            = var.region
  instance_name     = local.cloud_logs_instance_name
  resource_tags     = var.resource_tags
  access_tags       = var.access_tags
  data_storage = {
    # logs and metrics buckets must be different
    logs_data = {
      enabled         = true
      bucket_crn      = module.buckets.buckets[local.logs_bucket_name].bucket_crn
      bucket_endpoint = module.buckets.buckets[local.logs_bucket_name].s3_endpoint_direct
    },
    metrics_data = {
      enabled         = true
      bucket_crn      = module.buckets.buckets[local.metrics_bucket_name].bucket_crn
      bucket_endpoint = module.buckets.buckets[local.metrics_bucket_name].s3_endpoint_direct
    }
  }
  policies = [{
    logs_policy_name     = "${var.prefix}-logs-policy-1"
    logs_policy_priority = "type_low"
    application_rule = [{
      name         = "test-system-app"
      rule_type_id = "start_with"
    }]
    log_rules = [{
      severities = ["info", "debug"]
    }]
    subsystem_rule = [{
      name         = "test-sub-system"
      rule_type_id = "start_with"
    }]
  }]
  existing_event_notifications_instances = [{
    en_instance_id      = module.event_notification_1.guid
    en_region           = var.region
    en_integration_name = "${var.prefix}-en-1"
    },
    {
      en_instance_id      = module.event_notification_2.guid
      en_region           = var.region
      en_integration_name = "${var.prefix}-en-2"
  }]
}
