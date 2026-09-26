output "db_host" {
  description = "Hostname only (no port); passed to the app as DB_HOST."
  value       = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "db_secret_arn" {
  description = "RDS-managed secret; passed to the app as DB_SECRET_ARN."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "db_instance_arn" {
  value = aws_db_instance.this.arn
}
