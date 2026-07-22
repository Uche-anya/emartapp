# Deliberately kept out of main.tf. Destroying the app should not destroy the
# thing that warns me about spending, and these two have no reason to share a
# lifecycle.

variable "budget_notification_email" {
  description = "Address that receives budget alerts"
  type        = string
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = "1.0"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits count against the budget, so this tracks what actually lands on the
  # card rather than gross usage. While free-tier credits cover everything the
  # figure sits at zero; the first alert means the credits are gone.
  cost_types {
    include_credit = true
    include_refund = false
    use_amortized  = false
  }

  # Money already spent this month
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # Where this month is heading, which arrives days earlier than the above
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
