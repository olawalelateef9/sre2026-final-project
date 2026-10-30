# Alerts, each linking to its runbook section. Thresholds suit the low-traffic sandbox.

locals {
  monitors = {
    availability = {
      name     = "[techbleat] Public error rate above 5%"
      type     = "query alert"
      query    = "sum(last_5m):sum:${local.gateway_errors}.as_count() / sum:${local.gateway_requests}.as_count() > 0.05"
      critical = 0.05
      warning  = 0.02
      runbook  = "high-error-rate"
      text     = "More than 5% of public requests are failing with 5xx at the gateway."
    }
    latency = {
      name     = "[techbleat] Public latency above 1 s"
      type     = "query alert"
      query    = "avg(last_10m):sum:istio.mesh.request.duration.milliseconds.sum.total{reporter:source,source_workload:public-istio}.as_count() / sum:istio.mesh.request.duration.milliseconds.count.total{reporter:source,source_workload:public-istio}.as_count() > 1000"
      critical = 1000
      warning  = 500
      runbook  = "high-latency"
      text     = "Average gateway response time is above 1 second."
    }
    crashloop = {
      name     = "[techbleat] Container crash-looping"
      type     = "query alert"
      query    = "max(last_10m):sum:kubernetes_state.container.status_report.count.waiting{reason:crashloopbackoff,kube_cluster_name:techbleat} by {kube_namespace,pod_name} >= 1"
      critical = 1
      warning  = null
      runbook  = "pod-crash-looping"
      text     = "A container is in CrashLoopBackOff."
    }
    memory = {
      name     = "[techbleat] Container memory near its limit"
      type     = "query alert"
      query    = "avg(last_10m):avg:kubernetes.memory.usage_pct{kube_cluster_name:techbleat,kube_namespace:banking} by {kube_deployment} > 0.9"
      critical = 0.9
      warning  = 0.8
      runbook  = "saturation"
      text     = "A banking workload is using more than 90% of its memory limit."
    }
    node_cpu = {
      name     = "[techbleat] Node CPU saturated"
      type     = "query alert"
      query    = "avg(last_15m):avg:system.cpu.user{kube_cluster_name:techbleat} by {host} > 85"
      critical = 85
      warning  = 70
      runbook  = "saturation"
      text     = "A worker node has been above 85% CPU for 15 minutes."
    }
    auth_failures = {
      name     = "[techbleat] Spike in authentication failures"
      type     = "log alert"
      query    = "logs(\"authentication_failed\").index(\"*\").rollup(\"count\").last(\"5m\") > 20"
      critical = 20
      warning  = 10
      runbook  = "authentication-failures"
      text     = "More than 20 rejected tokens in 5 minutes across the APIs (forged, expired or replayed tokens, or a misconfigured client)."
    }
    authz_denials = {
      name     = "[techbleat] Suspicious authorization denials"
      type     = "log alert"
      query    = "logs(\"authorization_denied\").index(\"*\").rollup(\"count\").last(\"5m\") > 5"
      critical = 5
      warning  = 2
      runbook  = "authorization-denials"
      text     = "Authenticated callers were denied access more than 5 times in 5 minutes. This includes attempts to read or move another customer's money."
    }
    kafka = {
      name     = "[techbleat] Kafka broker not ready"
      type     = "query alert"
      query    = "max(last_5m):sum:kubernetes_state.pod.ready{kube_cluster_name:techbleat,kube_namespace:banking,pod_name:banking-kafka-dual-role-0,condition:true} < 1"
      critical = 1
      warning  = null
      runbook  = "data-service-outage"
      text     = "The Kafka broker is not ready. Transaction events and the activity feed are affected."
    }
    rds_cpu = {
      name     = "[techbleat] Database CPU high"
      type     = "query alert"
      query    = "avg(last_15m):avg:aws.rds.cpuutilization{dbinstanceidentifier:techbleat-*} by {dbinstanceidentifier} > 80"
      critical = 80
      warning  = 60
      runbook  = "data-service-outage"
      text     = "An RDS instance has been above 80% CPU for 15 minutes."
    }
    rds_storage = {
      name     = "[techbleat] Database storage low"
      type     = "query alert"
      query    = "min(last_15m):avg:aws.rds.free_storage_space{dbinstanceidentifier:techbleat-*} by {dbinstanceidentifier} < 2000000000"
      critical = 2000000000
      warning  = 5000000000
      runbook  = "data-service-outage"
      text     = "An RDS instance has less than 2 GB of free storage."
    }
    cache_cpu = {
      name     = "[techbleat] Valkey cache CPU high"
      type     = "query alert"
      query    = "avg(last_15m):avg:aws.elasticache.cpuutilization{replication_group:techbleat-valkey} > 80"
      critical = 80
      warning  = 60
      runbook  = "data-service-outage"
      text     = "The Valkey cache has been above 80% CPU for 15 minutes."
    }
    keycloak = {
      name     = "[techbleat] Keycloak not running"
      type     = "query alert"
      query    = "max(last_10m):avg:aws.ecs.service.running{clustername:techbleat-identity,servicename:keycloak} < 1"
      critical = 1
      warning  = null
      runbook  = "identity-outage"
      text     = "No Keycloak task is running on ECS: customers cannot sign in."
    }
  }
}

resource "datadog_monitor" "this" {
  for_each = local.monitors

  name    = each.value.name
  type    = each.value.type
  query   = each.value.query
  message = <<-EOT
    ${each.value.text}

    Runbook: ${local.runbook}#${each.value.runbook}

    ${local.notify}
  EOT

  monitor_thresholds {
    critical = each.value.critical
    warning  = each.value.warning
  }

  notify_no_data      = false
  require_full_window = false
  include_tags        = true
  tags                = local.tags
}
