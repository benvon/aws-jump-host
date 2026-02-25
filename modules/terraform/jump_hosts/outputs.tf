output "hosts" {
  description = "Computed metadata for provisioned jump hosts keyed by host name."
  value = {
    for host_name, instance in aws_instance.host : host_name => {
      instance_id          = instance.id
      private_ip           = instance.private_ip
      az                   = instance.availability_zone
      home_volume_id       = aws_ebs_volume.home[host_name].id
      access_profile       = local.normalized_hosts[host_name].access_profile
      run_as_default_user  = local.normalized_hosts[host_name].run_as_default_user
      security_group_ids   = instance.vpc_security_group_ids
    }
  }
}

output "created_security_group_ids" {
  description = "Security groups created by this module when host-specific IDs were omitted."
  value       = { for k, sg in aws_security_group.default : k => sg.id }
}

output "instance_profile_arn" {
  description = "IAM instance profile arn attached to all jump hosts."
  value       = aws_iam_instance_profile.instance.arn
}
