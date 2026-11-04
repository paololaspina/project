
# CloudWatch-Monitoring fuer unser AWS-CI/CD-Lab

# Alarm: CPU-Auslastung ueber 80 % fuer 10 Minuten
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cicd-webserver-cpu-high"
  alarm_description   = "CPU-Auslastung ueber 80 Prozent"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.web.id
  }

  tags = {
    Project = "cicd-lab"
  }
}

# Alarm: EC2-Statuspruefung fehlgeschlagen
resource "aws_cloudwatch_metric_alarm" "status_failed" {
  alarm_name          = "cicd-webserver-status-failed"
  alarm_description   = "EC2-Statuspruefung fehlgeschlagen"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.web.id
  }

  tags = {
    Project = "cicd-lab"
  }
}

# CloudWatch-Dashboard
resource "aws_cloudwatch_dashboard" "cicd" {
  dashboard_name = "cicd-lab-monitoring"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "EC2 - CPU-Auslastung"
          region = "us-east-1"
          period = 300
          stat   = "Average"

          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web.id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "EC2 - Netzwerkverkehr"
          region = "us-east-1"
          period = 300

          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.web.id],
            [".", "NetworkOut", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          title  = "EC2 - Statuspruefungen"
          region = "us-east-1"
          period = 60
          stat   = "Maximum"

          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.web.id]
          ]
        }
      }
    ]
  })
}
