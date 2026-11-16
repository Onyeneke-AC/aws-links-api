variable "name" {
  description = "Prefix for every resource, e.g. \"links-dev\"."
  type        = string
}

# ---- what to watch (outputs of the other modules) ---------------------------------

variable "alb_arn_suffix" {
  description = "CloudWatch's ID for the ALB (edge module)."
  type        = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "db_instance_id" {
  type = string
}

variable "app_log_group_name" {
  type = string
}

# ---- who to tell -------------------------------------------------------------------

variable "alarm_email" {
  description = "Email for SLO alerts. Kept out of the repo: set TF_VAR_alarm_email. Empty = no subscription (alarms still visible in the console)."
  type        = string
  default     = ""
}

# ---- the SLO -----------------------------------------------------------------------

variable "slo_target_percent" {
  description = "Share of requests that must not fail (5xx), over a rolling 7 days."
  type        = number
  default     = 99.5
}

variable "burn_rate" {
  description = "How many times faster than 'allowed' the error budget must be burning to page. 14.4 is the common fast-burn threshold (Google SRE workbook)."
  type        = number
  default     = 14.4
}

variable "min_requests_short" {
  description = "Below this many requests in the 5-minute window, don't judge the error rate: 1 failure out of 3 requests is 33%, but it's noise, not an outage."
  type        = number
  default     = 10
}

variable "min_requests_long" {
  description = "Same guard for the 1-hour window."
  type        = number
  default     = 60
}

# Where the load balancer's request, 5xx and latency metrics are read from.
# On AWS the ALB publishes them to AWS/ApplicationELB. The local AWS Emulator's
# load balancer publishes none, and no one may publish into an AWS/ namespace,
# so emulator runs publish the same metric names and dimensions to their own
# namespace (scripts/traffic.sh) and the alarms read them from there.
variable "alb_metrics_namespace" {
  type     = string
  default  = "AWS/ApplicationELB"
  nullable = false
}
