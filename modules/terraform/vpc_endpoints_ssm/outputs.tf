output "endpoint_ids" {
  description = "VPC endpoint IDs keyed by service name."
  value       = { for svc, ep in aws_vpc_endpoint.interface : svc => ep.id }
}

output "endpoint_dns_names" {
  description = "Primary endpoint DNS entries keyed by service name."
  value = {
    for svc, ep in aws_vpc_endpoint.interface : svc => try(ep.dns_entry[0].dns_name, null)
  }
}
