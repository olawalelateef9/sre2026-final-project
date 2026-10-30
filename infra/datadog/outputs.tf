output "dashboard_url" {
  value = "https://app.${var.datadog_site}${datadog_dashboard_json.service_health.url}"
}

output "slo_id" {
  value = datadog_service_level_objective.availability.id
}

output "monitor_ids" {
  value = { for key, monitor in datadog_monitor.this : key => monitor.id }
}
