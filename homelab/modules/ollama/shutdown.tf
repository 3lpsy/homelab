# --- Auto-shutdown at midnight Chicago time ---

resource "aws_iam_role" "ollama_shutdown" {
  name = "ollama-auto-shutdown"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ollama_shutdown" {
  name = "ollama-auto-shutdown"
  role = aws_iam_role.ollama_shutdown.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StopInstances", "ec2:DescribeInstances"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "ec2:ResourceTag/Name" = "headscale-ollama"
        }
      }
    }]
  })
}

data "archive_file" "shutdown_lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda/shutdown.zip"
  source {
    content  = <<-PYTHON
      import boto3
      import os
      def handler(event, context):
          ec2 = boto3.client('ec2', region_name=os.environ['AWS_REGION'])
          instance_id = os.environ['INSTANCE_ID']
          state = ec2.describe_instances(InstanceIds=[instance_id])['Reservations'][0]['Instances'][0]['State']['Name']
          if state == 'running':
              ec2.stop_instances(InstanceIds=[instance_id])
              return f"Stopped {instance_id}"
          return f"Instance {instance_id} already {state}"
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "ollama_shutdown" {
  function_name    = "ollama-auto-shutdown"
  role             = aws_iam_role.ollama_shutdown.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.shutdown_lambda.output_path
  source_code_hash = data.archive_file.shutdown_lambda.output_base64sha256

  environment {
    variables = {
      INSTANCE_ID = aws_instance.ollama.id
    }
  }
}

# Midnight CDT (summer) = 5:00 UTC
resource "aws_cloudwatch_event_rule" "midnight_shutdown_cdt" {
  name                = "ollama-midnight-shutdown-cdt"
  description         = "Stop ollama instance at midnight CDT"
  schedule_expression = "cron(0 5 * * ? *)"
}

resource "aws_cloudwatch_event_target" "shutdown_target_cdt" {
  rule = aws_cloudwatch_event_rule.midnight_shutdown_cdt.name
  arn  = aws_lambda_function.ollama_shutdown.arn
}

resource "aws_lambda_permission" "allow_eventbridge_cdt" {
  statement_id  = "AllowEventBridgeCDT"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ollama_shutdown.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.midnight_shutdown_cdt.arn
}

# Midnight CST (winter) = 6:00 UTC
resource "aws_cloudwatch_event_rule" "midnight_shutdown_cst" {
  name                = "ollama-midnight-shutdown-cst"
  description         = "Stop ollama instance at midnight CST"
  schedule_expression = "cron(0 6 * * ? *)"
}

resource "aws_cloudwatch_event_target" "shutdown_target_cst" {
  rule = aws_cloudwatch_event_rule.midnight_shutdown_cst.name
  arn  = aws_lambda_function.ollama_shutdown.arn
}

resource "aws_lambda_permission" "allow_eventbridge_cst" {
  statement_id  = "AllowEventBridgeCST"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ollama_shutdown.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.midnight_shutdown_cst.arn
}
