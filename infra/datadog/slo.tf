# User-facing SLO: availability of the public application, measured from real requests at
# the gateway. Good = any response that is not 5xx (4xx such as 401/403 are correct
# behaviour, not failures).

resource "datadog_service_level_objective" "availability" {
  name        = "[techbleat] Public availability"
  type        = "metric"
  description = "Share of public requests through the gateway that do not fail with 5xx. Error budget for 7 days at 99.5% is about 50 minutes of full outage."
  tags        = local.tags

  query {
    numerator   = "sum:${local.gateway_requests}.as_count() - sum:${local.gateway_errors}.as_count()"
    denominator = "sum:${local.gateway_requests}.as_count()"
  }

  thresholds {
    timeframe = "7d"
    target    = 99.5
    warning   = 99.8
  }

  thresholds {
    timeframe = "30d"
    target    = 99.5
    warning   = 99.8
  }
}

# Multi-window burn-rate alert: pages when the budget is being spent fast enough to run
# out within about half a day (14.4x burn over 1 hour, confirmed over 5 minutes).
resource "datadog_monitor" "slo_burn_rate" {
  name  = "[techbleat] Availability SLO burning fast"
  type  = "slo alert"
  query = "burn_rate(\"${datadog_service_level_objective.availability.id}\").over(\"7d\").long_window(\"1h\").short_window(\"5m\") > 14.4"

  message = <<-EOT
    The public availability SLO error budget is burning at more than 14.4x the sustainable rate.

    Runbook: ${local.runbook}#slo-burn

    ${local.notify}
  EOT

  monitor_thresholds {
    critical = 14.4
  }

  tags = local.tags
}
