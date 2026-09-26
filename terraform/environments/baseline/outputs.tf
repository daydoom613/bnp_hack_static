output "fleet" {
  description = "The static fleet whose cost is data/baseline_cost.json."
  value = {
    instance_type  = var.instance_type
    instance_count = var.instance_count
    purchase       = "on-demand"
    schedule       = "24x7"
  }
}
