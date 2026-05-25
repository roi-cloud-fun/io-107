output "bucket_name" {
  description = "Name of the S3 data bucket."
  value       = aws_s3_bucket.data_bucket.bucket
}

output "bucket_arn" {
  description = "ARN of the S3 data bucket."
  value       = aws_s3_bucket.data_bucket.arn
}

output "lambda_function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.processor.function_name
}

output "lambda_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.processor.arn
}
