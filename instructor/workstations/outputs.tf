output "workstations" {
  description = "Per-student workstation: instance id and public IP."
  value = {
    for s, i in aws_instance.workstation : s => {
      instance_id = i.id
      public_ip   = i.public_ip
      public_dns  = i.public_dns
      az          = i.availability_zone
    }
  }
}

output "instance_ids" {
  description = "Flat list of instance ids — what power.sh stops and starts."
  value       = [for i in aws_instance.workstation : i.id]
}

output "connect_hints" {
  description = "How each student reaches their box (EC2 Instance Connect needs no key pair)."
  value = {
    for s, i in aws_instance.workstation : s =>
    "Console -> EC2 -> Instances -> ${i.id} -> Connect -> EC2 Instance Connect (user: ec2-user)"
  }
}
