# Static IPv4 address for the Global TCP Load Balancer
resource "google_compute_global_address" "apiserver-global-ip" {
  name = "${var.cluster_name}-apiserver-ip"
  ip_version = "IPV4"
}

# DNS record for the Global TCP Load Balancer
resource "google_dns_record_set" "apiservers" {
  # DNS Zone name where record should be created
  managed_zone = "${var.dns_zone_name}"

  # DNS record
  name = "${format("%s.%s.", var.cluster_name, var.dns_zone)}"
  type = "A"
  ttl  = 300

  # IPv4 address of controllers' network load balancer
  rrdatas = ["${google_compute_global_address.apiserver-global-ip.address}"]
}

# Associate a global IP address to a target proxy
resource "google_compute_global_forwarding_rule" "apiserver" {
  name = "${var.cluster_name}-apiserver"
  ip_protocol = "TCP"
  ip_address = "${google_compute_global_address.apiserver-global-ip.address}"
  port_range = "443"
  target = "${google_compute_target_tcp_proxy.apiservers.self_link}"
}

# Global TCP Load Balancer (i.e. TCP target proxy)
resource "google_compute_target_tcp_proxy" "apiservers" {
  name = "${var.cluster_name}-apiserver"
  description = "Distribute TCP load across ${var.cluster_name} controllers"
  backend_service = "${google_compute_backend_service.apiserver.self_link}"
}

# Global backend service backed by unmanaged instance groups
resource "google_compute_backend_service" "apiserver" {
  name = "${var.cluster_name}-apiserver"
  description = "${var.cluster_name} apiserver service"

  protocol = "TCP"
  port_name = "apiserver"
  session_affinity = "NONE"
  timeout_sec = 3600

  # Cannot use `count` with repeated fields so use 3 groups (supported regions
  # have 3 or more zonal instance groups)
  backend {
    group = "${google_compute_instance_group.controllers.0.self_link}"
  }
  backend {
    group = "${google_compute_instance_group.controllers.1.self_link}"
  }
  backend {
    group = "${google_compute_instance_group.controllers.2.self_link}"
  }

  health_checks = ["${google_compute_health_check.apiserver.self_link}"]
}

# Organize instances into instance groups for use with backend services
resource "google_compute_instance_group" "controllers" {
  count = 3

  name = "${format("%s-controller-group-%d", var.cluster_name, count.index)}"
  zone = "${element(data.google_compute_zones.all.names, count.index)}"

  named_port {
    name = "apiserver"
    port = "443"
  }

  # add instances in the zone to the controller-group for that zone
  instances = [
    "${matchkeys(google_compute_instance.controllers.*.self_link,
      google_compute_instance.controllers.*.zone,
      list(element(data.google_compute_zones.all.names, count.index)))}"
  ]
}

# Health check the kube-apiserver pod is running
resource "google_compute_health_check" "apiserver" {
  name = "${var.cluster_name}-apiserver-health"
  description = "Health check kube-apiserver"

  timeout_sec = 5
  check_interval_sec = 5

  healthy_threshold = 1
  unhealthy_threshold = 4

  ssl_health_check {
    port  = 443
  }
}

/*
Network Load Balancer (regional) is a "correct" choice. However, it cannot be
used in multi-controller setups due to poor planning around health checking
in Kubernetes. It has long been known that kubelet 10255 read-only checks are
only a loose approximation for a healthy controller. On most platforms, this
is fine, kubelets eventually contact the bootstrap controller, register, and
begin running their own apiserver. On GCE, health checks pass immediately and
kubelet requests are reflected back to the current node, so only one master
can start the apiserver effectively. Solutions:

* Find a safe way to enable anonymous-auth to allow /healthz checks
* Health check with TLS probes only

The later is the most practical at the moment. Regional network load balancers
only support http/https health checks. The new TCP/SSL health checks can only
be used with global load balancers (HTTPS, SSL, TCL). So note, we are NOT using
a global load balancer because we need it to be global.

* https://github.com/kubernetes/kubernetes/issues/51076
*/
