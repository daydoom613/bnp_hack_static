# Waits for the policies too, so instances never boot with a role that
# cannot pull the image or read the DB secret yet.
output "instance_profile_name" {
  value = aws_iam_instance_profile.app_instance.name

  depends_on = [
    aws_iam_role_policy.app_instance,
    aws_iam_role_policy_attachment.ssm_core,
  ]
}

output "instance_role_name" {
  value = aws_iam_role.app_instance.name
}

output "instance_role_arn" {
  value = aws_iam_role.app_instance.arn
}
