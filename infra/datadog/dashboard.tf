resource "datadog_dashboard_json" "service_health" {
  dashboard = templatefile("${path.module}/dashboard.json.tftpl", {
    slo_id           = datadog_service_level_objective.availability.id
    gateway_requests = local.gateway_requests
    gateway_errors   = local.gateway_errors
  })
}
