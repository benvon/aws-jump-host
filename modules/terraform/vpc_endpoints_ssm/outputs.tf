output "endpoint_ids" {
  description = "VPC endpoint IDs keyed by service name."
  value = merge(
    { for svc, ep in aws_vpc_endpoint.interface : svc => ep.id },
    length(aws_vpc_endpoint.s3_gateway) > 0 ? { s3 = aws_vpc_endpoint.s3_gateway[0].id } : {}
  )
}

output "endpoint_dns_names" {
  description = "Primary endpoint DNS entries keyed by service name."
  value = {
    for svc, ep in aws_vpc_endpoint.interface : svc => try(ep.dns_entry[0].dns_name, null)
  }
}

output "created_security_group_ids" {
  description = "Module-managed security group IDs keyed by service name. Empty when caller supplies security_group_ids."
  value       = { for svc, sg in aws_security_group.endpoint : svc => sg.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint ID when enabled."
  value       = try(aws_vpc_endpoint.s3_gateway[0].id, null)
}
