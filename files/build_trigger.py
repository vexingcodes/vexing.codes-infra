import boto3
def handler(event, _):
  boto3.client('codebuild').start_build(
    projectName=event['Records'][0]['customData'])
